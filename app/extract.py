from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

from google import genai
from google.genai import types

from app.config import settings
from app.errors import gemini_is_quota_exhausted
from app.models import RECIPE_TAGS, FetchedPost, FetchedSlide, Recipe, RecipeCategory, RecipeSet
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
- If this is not a recipe at all → one object with a short title, empty lists, confidence "low", and meal "other".

Rules:
- Quantities and units should be as specific as the content allows. Copy them exactly when they appear (for example "1.5 lb / 750 g", "2 tbsp"). Use "" only if the source truly has no amount. Do not replace a measured line with a bare ingredient name. For a multi-component meal, prefix the item with the component when needed (for example "Sauce: yogurt", "Chicken: cumin").
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


def _gemini_api_keys() -> list[str]:
    """GEMINI_API_KEY, plus the optional GEMINI_API_KEY_2 (a second Google
    account's own free-tier key) if set — see app.config. The free tier's
    daily cap is per key/project, so once the first is exhausted for the
    day, extract_recipe falls back to the second instead of failing for
    the rest of the day."""
    keys = [settings.gemini_api_key, settings.gemini_api_key_2]
    return [key.strip() for key in keys if key.strip()]


def _client_timeout_ms() -> int:
    """Client-level timeout for calls other than generate_content (file
    upload/poll below). generate_content uses per-model timeouts in
    _generate_with_retry."""
    return 200_000 if os.environ.get("VERCEL") else 170_000


def extract_recipe(post: FetchedPost) -> list[Recipe]:
    keys = _gemini_api_keys()
    if not keys:
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    call_timeout_ms = _client_timeout_ms()
    caption_part = PROMPT.format(caption=post.caption or "(no caption)")
    slides = list(post.slides)
    if not slides:
        if post.video_path:
            slides = [FetchedSlide(kind="video", path=post.video_path)]
        else:
            still_paths = [Path(p) for p in post.image_paths if p]
            if not still_paths and post.thumbnail_path:
                still_paths = [Path(post.thumbnail_path)]
            slides = [FetchedSlide(kind="image", path=str(path)) for path in still_paths]

    last_error: Exception | None = None
    for index, api_key in enumerate(keys):
        # A fresh client (and, for the upload path, a fresh upload) per
        # key: an uploaded file is scoped to the project that uploaded it,
        # so a fallback key can't reuse the first key's upload.
        client = genai.Client(api_key=api_key, http_options=types.HttpOptions(timeout=call_timeout_ms))
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
            text = _generate_with_retry(
                client,
                contents,
                RecipeSet,
                timeout_ms=(70_000 if os.environ.get("VERCEL") and video_count > 1 else None),
            )
            return _parse_recipe_set(text)
        except Exception as exc:
            last_error = exc
            if gemini_is_quota_exhausted(exc) and index < len(keys) - 1:
                logger.warning("Gemini key %d/%d hit its daily quota; trying the next key", index + 1, len(keys))
                continue
            raise
        finally:
            for file in uploaded:
                try:
                    client.files.delete(name=file.name)
                except Exception:
                    logger.debug("Could not delete Gemini file %s", getattr(file, "name", file))
    raise RuntimeError("Gemini call failed") from last_error


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


def _generate_with_retry(
    client: genai.Client,
    contents,
    response_schema: type,
    attempts: int = 5,
    timeout_ms: int | None = None,
) -> str:
    """One generate_content on settings.gemini_model. On Vercel Hobby the
    function may run 300s; this call gets one shot so a slow reply is not
    billed twice. Locally, a daily-quota 429 can retry on the same key
    before extract_recipe tries the next key.

    Shared by extract_recipe (contents = recipe prompt + media, schema =
    Recipe) and categorize_recipe (contents = category prompt, schema =
    RecipeCategory)."""
    on_vercel = bool(os.environ.get("VERCEL"))
    if on_vercel:
        attempts = 1
    if timeout_ms is None:
        timeout_ms = 140_000 if on_vercel else 170_000

    last_error: Exception | None = None
    for i in range(attempts):
        try:
            record_gemini_read()
            response = client.models.generate_content(
                model=settings.gemini_model,
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
        except Exception as exc:
            last_error = exc
            if gemini_is_quota_exhausted(exc) and i < attempts - 1:
                delay = 2 ** (i + 1)
                logger.warning("Gemini rate-limited; retrying in %ss", delay)
                time.sleep(delay)
                continue
            raise
    raise RuntimeError("Gemini call failed") from last_error


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
    text = _generate_with_retry(client, prompt, RecipeCategory)
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
    if not recipes:
        try:
            recipes = [_parse_recipe(text)]
        except Exception:
            raise RuntimeError(f"Could not parse recipe JSON: {text[:400]}")
    filled = [item for item in recipes if item.ingredients or item.steps]
    return (filled or recipes)[:5]


def _parse_recipe(text: str) -> Recipe:
    try:
        return Recipe.model_validate_json(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1:
            raise RuntimeError(f"Could not parse recipe JSON: {text[:400]}")
        return Recipe.model_validate(json.loads(text[start : end + 1]))
