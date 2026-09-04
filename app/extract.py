from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

from google import genai
from google.genai import types

from pydantic import BaseModel, Field

from app.config import settings
from app.errors import NOT_A_RECIPE_MESSAGE, gemini_is_busy, gemini_is_quota_exhausted
from app.match import apply_section_labels
from app.models import RECIPE_TAGS, FetchedPost, FetchedSlide, Recipe, RecipeCategory, RecipeSet, recipe_is_importable
from app.store import record_gemini_read

logger = logging.getLogger(__name__)

# Comma-joined once, reused in both prompts below — kept as a single source
# (RECIPE_TAGS in app/models.py) rather than duplicated text, since the
# model layer already enforces this same list regardless of what Gemini
# picks. Telling Gemini the real list up front means it usually picks
# something that actually survives that filter, instead of inventing tags
# that just get silently dropped.
_TAGS_LIST = ", ".join(f'"{tag}"' for tag in RECIPE_TAGS)

PROMPT = f"""Extract recipes from this saved recipe content.

Priority:
- The TEXT below is the Instagram caption plus any owner comments we found. If that text already has a real recipe (ingredients and/or steps, including quantities), treat it as the source of truth. Do not replace those amounts or steps with something you only heard or saw in the video.
- Use attached video(s) and image(s) to fill gaps (missing steps, technique, a dish with no recipe in the text) or when the TEXT has no usable recipe.
- If several short videos are attached, they are carousel clips in order. Watch every clip, but still prefer TEXT when it already contains the recipe.
- If images are attached, they are in order (carousel or a single photo). Look at every image, same TEXT-first rule.
- If nothing is attached, the TEXT is the full source (caption, comments, or a recipe blog page).

How many recipes to return:
- One recipe whose ingredients/steps are spread across several slides or clips → return exactly one object, combining those slides.
- Components of one meal that are meant to be eaten together (for example a sauce, grilled chicken, and rice) → return exactly one object. Keep each component's ingredients and steps together, in order (sauce, then chicken, then rice, then how to plate/serve). Do not save those as three separate recipes.
- Several clearly unrelated dishes in the same carousel (for example cookies and a soup, or two different dinners) → return one object per complete recipe (maximum 5).
- Intro, title, or collage slides that are not a recipe → skip them.
- First decide content_kind. Use "recipe" only if the post is meant to teach someone how to cook a dish (ingredients and a method). Use "not_recipe" for vlogs, news, events, interviews, travel, memes, ads, product posts, restaurant visits, or anything that merely shows food. A civic event, a "day in my life", or someone eating on camera is not_recipe even if a plate is visible.
- Never invent a recipe to match a video's title, setting, or vibe. If the TEXT is not a recipe and the video is not teaching a dish, content_kind is "not_recipe".
- Many recipe reels put the method only in the video, with a short caption and no ingredient list in TEXT. Those are still "recipe" if the video teaches a dish.

Rules:
- is_recipe must be true only for a real dish to save. If you are unsure, set content_kind to "not_recipe" and return no recipes.
- Quantities and units should be as specific as the content allows. Copy them exactly when they appear (for example "1.5 lb / 750 g", "2 tbsp"). Use "" only if the source truly has no amount. Do not replace a measured line with a bare ingredient name.
- For a multi-component meal (sauce, chicken, rice, and so on), set each ingredient's "section" to a short cook-facing label such as "For the sauce" and put only the ingredient in "item" (not "Sauce: yogurt"). Leave section empty when the recipe is a single list.
- Steps should be a cook-along list, one action per item, in order. For a multi-component meal, start a component with a short label step such as "Sauce:" then the actions for that part.
- cuisine: a short regional label such as Indian, Italian, Mexican, East Asian, Middle Eastern, or American. Use Other only if it truly has no regional identity.
- meal: breakfast, lunch, dinner, snack, dessert, drink, or other.
- time: total time if mentioned (for example "30 min"), otherwise null.
- tags: choose only from this fixed list, whichever genuinely apply — {_TAGS_LIST}. Do not invent any other tag. Leave it empty if none clearly apply.
- Return JSON only, matching the schema. No markdown.

TEXT:
{{caption}}
"""

CATEGORY_PROMPT = f"""Categorize this saved recipe.

cuisine: a short label such as Indian, Italian, Mexican, East Asian, Middle Eastern, American, or Other.
meal: breakfast, lunch, dinner, snack, dessert, drink, or other.
time: total time if mentioned, otherwise null.
tags: choose only from this fixed list, whichever genuinely apply — {_TAGS_LIST}. Do not invent any other tag. Leave it empty if none clearly apply.

TITLE: {{title}}
SERVINGS: {{servings}}
INGREDIENTS:
{{ingredients}}
STEPS:
{{steps}}
CAPTION:
{{caption}}
"""


def _client_timeout_ms() -> int:
    """Client-level timeout for calls other than generate_content (file
    upload/poll below). generate_content uses per-model timeouts in
    _generate_with_retry."""
    return 200_000 if os.environ.get("VERCEL") else 170_000


def extract_recipe(post: FetchedPost) -> tuple[list[Recipe], bool]:
    if not settings.gemini_api_key.strip():
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    caption = post.caption or ""
    call_timeout_ms = _client_timeout_ms()
    caption_part = PROMPT.format(caption=caption or "(no caption)")
    slides = list(post.slides)
    if not slides:
        if post.video_path:
            slides = [FetchedSlide(kind="video", path=post.video_path)]
        else:
            still_paths = [Path(p) for p in post.image_paths if p]
            if not still_paths and post.thumbnail_path:
                still_paths = [Path(post.thumbnail_path)]
            slides = [FetchedSlide(kind="image", path=str(path)) for path in still_paths]

    client = genai.Client(
        api_key=settings.gemini_api_key,
        http_options=types.HttpOptions(timeout=call_timeout_ms),
    )
    uploaded: list = []
    try:
        contents: list = []
        video_count = sum(1 for slide in slides if slide.kind == "video")
        upload_timeout = 15 if os.environ.get("VERCEL") and video_count > 1 else (45 if os.environ.get("VERCEL") else 180)
        for slide in slides:
            path = Path(slide.path)
            if slide.kind == "image":
                inline = _inline_image_part(path)
                if inline is not None:
                    contents.append(inline)
                else:
                    logger.warning("Skipping non-image media %s", path.name)
                continue
            file = _upload_and_wait(client, path, timeout=upload_timeout)
            uploaded.append(file)
            contents.append(file)
        contents.append(caption_part)
        text, used_backup = _generate_with_retry(
            client,
            contents,
            RecipeSet,
            timeout_ms=(70_000 if os.environ.get("VERCEL") and video_count > 1 else None),
        )
        return _parse_recipe_set(text), used_backup
    finally:
        for file in uploaded:
            try:
                client.files.delete(name=file.name)
            except Exception:
                logger.debug("Could not delete Gemini file %s", getattr(file, "name", file))


_IMAGE_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
}


def _inline_image_part(path: Path) -> types.Part | None:
    """Stills go inline so we skip Gemini's Files upload+poll — that wait
    alone can blow Vercel's 60s budget (and the phone's request timer)
    before generate_content even starts."""
    mime = _IMAGE_MIME.get(path.suffix.lower())
    if not mime:
        return None
    return types.Part.from_bytes(data=path.read_bytes(), mime_type=mime)


def _upload_and_wait(client: genai.Client, path: Path, timeout: int = 180):
    logger.info("Uploading %s to Gemini", path.name)
    uploaded = client.files.upload(file=str(path))
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = getattr(uploaded.state, "name", None) or str(uploaded.state)
        if state == "ACTIVE":
            return uploaded
        if state == "FAILED":
            raise RuntimeError("Gemini failed to process the uploaded media.")
        time.sleep(3)
        uploaded = client.files.get(name=uploaded.name)
    raise TimeoutError("Timed out waiting for Gemini to process the video.")


def _generate_once(
    client: genai.Client,
    model: str,
    contents,
    response_schema: type,
    timeout_ms: int,
) -> str:
    record_gemini_read()
    response = client.models.generate_content(
        model=model,
        contents=contents,
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=response_schema,
            thinking_config=types.ThinkingConfig(
                thinking_level=types.ThinkingLevel.MINIMAL,
            ),
            http_options=types.HttpOptions(timeout=timeout_ms),
        ),
    )
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    return text


def _generate_with_retry(
    client: genai.Client,
    contents,
    response_schema: type,
    timeout_ms: int | None = None,
) -> tuple[str, bool]:
    """One generate_content on the primary model, then one shot on the
    fallback model if the primary is busy or out of daily quota.

    Shared by extract_recipe (contents = recipe prompt + media, schema =
    RecipeSet) and categorize_recipe (contents = category prompt, schema =
    RecipeCategory). Returns (json_text, used_backup)."""
    on_vercel = bool(os.environ.get("VERCEL"))
    if timeout_ms is None:
        timeout_ms = 140_000 if on_vercel else 170_000

    try:
        return (
            _generate_once(client, settings.gemini_model, contents, response_schema, timeout_ms),
            False,
        )
    except Exception as exc:
        if not (gemini_is_busy(exc) or gemini_is_quota_exhausted(exc)):
            raise
        fallback = settings.gemini_fallback_model.strip()
        if not fallback or fallback == settings.gemini_model:
            raise
        logger.warning("Primary Gemini model failed (%s); trying fallback", type(exc).__name__)
        try:
            return (
                _generate_once(client, fallback, contents, response_schema, timeout_ms),
                True,
            )
        except Exception as fallback_exc:
            fallback_exc.used_backup = True  # type: ignore[attr-defined]
            raise


def categorize_recipe(
    title: str,
    ingredients: str,
    steps: str,
    caption: str = "",
    servings: str = "",
) -> RecipeCategory:
    if not settings.gemini_api_key:
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    client = genai.Client(api_key=settings.gemini_api_key, http_options=types.HttpOptions(timeout=_client_timeout_ms()))
    prompt = CATEGORY_PROMPT.format(
        title=title or "(untitled)",
        servings=servings or "",
        ingredients=ingredients or "(none)",
        steps=steps or "(none)",
        caption=caption or "(none)",
    )
    text, _used_backup = _generate_with_retry(client, prompt, RecipeCategory)
    try:
        return RecipeCategory.model_validate_json(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1:
            raise RuntimeError(f"Could not parse category JSON: {text[:400]}")
        return RecipeCategory.model_validate(json.loads(text[start : end + 1]))


def _parse_recipe_set(text: str) -> list[Recipe]:
    parsed = None
    try:
        parsed = RecipeSet.model_validate_json(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1:
            try:
                parsed = RecipeSet.model_validate(json.loads(text[start : end + 1]))
            except Exception:
                parsed = None
    recipes = list(parsed.recipes) if parsed else []
    if parsed is not None and parsed.content_kind == "not_recipe":
        raise RuntimeError(NOT_A_RECIPE_MESSAGE)
    if not recipes:
        if parsed is not None:
            raise RuntimeError(NOT_A_RECIPE_MESSAGE)
        try:
            recipes = [_parse_recipe(text)]
        except Exception:
            raise RuntimeError(f"Could not parse recipe JSON: {text[:400]}")
    filled = [
        item
        for item in recipes
        if recipe_is_importable(item)
    ]
    if filled:
        return filled[:5]
    raise RuntimeError(NOT_A_RECIPE_MESSAGE)


def _parse_recipe(text: str) -> Recipe:
    try:
        return Recipe.model_validate_json(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1:
            raise RuntimeError(f"Could not parse recipe JSON: {text[:400]}")
        return Recipe.model_validate(json.loads(text[start : end + 1]))


class _IngredientSectionHit(BaseModel):
    n: int
    section: str = ""


class _RecipeSectionHit(BaseModel):
    id: int
    parts: list[_IngredientSectionHit] = Field(default_factory=list)


class _RecipeSectionBatch(BaseModel):
    recipes: list[_RecipeSectionHit] = Field(default_factory=list)


_SECTION_BACKFILL_PROMPT = """Assign ingredient-list section headings for saved recipes.

For each recipe, look at the title, ingredient lines, and steps. If this is one mixed list (a single marinade, a single batter, one soup), leave every section empty.
If it is a multi-part meal that cooks would split on the page (chicken vs sauce vs rice vs slaw vs "to serve"), give each ingredient a short cook-facing label such as "For the chicken", "For the sauce", "For the rice", "To serve". Consecutive ingredients of the same part share the same label.

Rules:
- Do not add, remove, rewrite, or reorder ingredients. Only assign a section label per line number.
- Every ingredient line number in the input must appear once in parts.
- Use empty section when unsure.

RECIPES:
{body}
"""


def suggest_ingredient_sections(recipes: list[dict]) -> dict[int, list[str]]:
    """Gemini labels for a batch of already-saved recipes. Keys are row
    ids; values are full ingredient lists with `##` headings inserted, or
    omitted when the recipe should stay a flat list."""
    if not settings.gemini_api_key.strip():
        raise RuntimeError("GEMINI_API_KEY is missing.")
    chunks: list[str] = []
    wanted: dict[int, list[str]] = {}
    for recipe in recipes:
        row_id = int(recipe["id"])
        lines = list(recipe.get("ingredients") or [])
        if not lines or any(line.strip().startswith("#") for line in lines):
            continue
        wanted[row_id] = lines
        steps = recipe.get("steps") or []
        numbered = "\n".join(f"  {i}. {line}" for i, line in enumerate(lines, start=1))
        step_text = "\n".join(f"  - {step}" for step in steps[:12]) or "  (none)"
        chunks.append(
            f"id {row_id}\nTITLE: {recipe.get('title') or '(untitled)'}\nINGREDIENTS:\n{numbered}\nSTEPS:\n{step_text}"
        )
    if not wanted:
        return {}
    prompt = _SECTION_BACKFILL_PROMPT.format(body="\n\n".join(chunks))
    client = genai.Client(
        api_key=settings.gemini_api_key,
        http_options=types.HttpOptions(timeout=_client_timeout_ms()),
    )
    text, _used_backup = _generate_with_retry(client, prompt, _RecipeSectionBatch)

    try:
        parsed = _RecipeSectionBatch.model_validate_json(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1:
            raise RuntimeError(f"Could not parse section JSON: {text[:400]}")
        parsed = _RecipeSectionBatch.model_validate(json.loads(text[start : end + 1]))

    out: dict[int, list[str]] = {}
    by_id = {item.id: item for item in parsed.recipes}
    for row_id, lines in wanted.items():
        hit = by_id.get(row_id)
        if not hit:
            continue
        labels = [""] * len(lines)
        for part in hit.parts:
            index = part.n - 1
            if 0 <= index < len(labels):
                labels[index] = (part.section or "").strip()
        rewritten = apply_section_labels(lines, labels)
        if rewritten:
            out[row_id] = rewritten
    return out
