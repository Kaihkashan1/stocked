from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

from google import genai
from google.genai import types

from app.config import settings
from app.errors import gemini_is_busy, gemini_is_quota_exhausted
from app.models import RECIPE_TAGS, FetchedPost, Recipe, RecipeCategory
from app.store import record_gemini_read

logger = logging.getLogger(__name__)

# Comma-joined once, reused in both prompts below — kept as a single source
# (RECIPE_TAGS in app/models.py) rather than duplicated text, since the
# model layer already enforces this same list regardless of what Gemini
# picks. Telling Gemini the real list up front means it usually picks
# something that actually survives that filter, instead of inventing tags
# that just get silently dropped.
_TAGS_LIST = ", ".join(f'"{tag}"' for tag in RECIPE_TAGS)

PROMPT = f"""Extract exactly one recipe from this saved recipe content.

If a video and/or image is attached, watch/look at it alongside the text below —
prefer spoken instructions and on-screen text over the text if they disagree.
If nothing is attached, the text below is the full source (a caption, or the
text of a recipe blog page): read it directly.

Rules:
- Quantities and units should be as specific as the content allows. Copy them exactly when they appear (for example "1.5 lb / 750 g", "2 tbsp"). Use "" only if the source truly has no amount. Do not replace a measured line with a bare ingredient name.
- Steps should be a cook-along list, one action per item, in order.
- cuisine: a short regional label such as Indian, Italian, Mexican, East Asian, Middle Eastern, or American. Use Other only if it truly has no regional identity.
- meal: breakfast, lunch, dinner, snack, dessert, drink, or other.
- time: total time if mentioned (for example "30 min"), otherwise null.
- tags: choose only from this fixed list, whichever genuinely apply — {_TAGS_LIST}. Do not invent any other tag. Leave it empty if none clearly apply.
- If this is not a recipe, still return JSON with a short title, empty lists, confidence "low", and meal "other".
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
    upload/poll below). generate_content itself gets its own, tighter,
    per-model timeouts in _generate_with_retry so a primary-model
    overload still leaves room for the gemini-2.5-flash fallback under
    Vercel's 60s cap."""
    return 50_000 if os.environ.get("VERCEL") else 170_000


def extract_recipe(post: FetchedPost) -> Recipe:
    keys = _gemini_api_keys()
    if not keys:
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    call_timeout_ms = _client_timeout_ms()
    media_path = post.video_path or post.thumbnail_path
    caption_part = PROMPT.format(caption=post.caption or "(no caption)")

    last_error: Exception | None = None
    for index, api_key in enumerate(keys):
        # A fresh client (and, for the upload path, a fresh upload) per
        # key: an uploaded file is scoped to the project that uploaded it,
        # so a fallback key can't reuse the first key's upload.
        client = genai.Client(api_key=api_key, http_options=types.HttpOptions(timeout=call_timeout_ms))
        uploaded = None
        try:
            contents: list = []
            if media_path:
                path = Path(media_path)
                inline = _inline_image_part(path)
                if inline is not None:
                    contents.append(inline)
                else:
                    uploaded = _upload_and_wait(client, path)
                    contents.append(uploaded)
            contents.append(caption_part)
            text = _generate_with_retry(client, contents, Recipe)
            return _parse_recipe(text)
        except Exception as exc:
            last_error = exc
            if gemini_is_quota_exhausted(exc) and index < len(keys) - 1:
                logger.warning("Gemini key %d/%d hit its daily quota; trying the next key", index + 1, len(keys))
                continue
            raise
        finally:
            if uploaded is not None:
                try:
                    client.files.delete(name=uploaded.name)
                except Exception:
                    logger.debug("Could not delete Gemini file %s", uploaded.name)
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


def _generate_with_retry(client: genai.Client, contents, response_schema: type, attempts: int = 5) -> str:
    """Tries settings.gemini_model first, then — only when it's genuinely
    overloaded (gemini_is_busy: 503/"high demand"/deadline, not a daily
    quota 429) — falls back to the lighter gemini_fallback_model. Both
    calls have to fit inside Vercel's 60s function cap, so on Vercel each
    gets one shot with its own short timeout instead of one call sharing
    a long one (a short timeout + retry there was billing two requests
    for saves that used to finish in a single slower call). Locally,
    where there's no hard cap, the primary model also gets a few
    same-key retries on a daily-quota 429 before falling back.

    Shared by extract_recipe (contents = recipe prompt + media, schema =
    Recipe) and categorize_recipe (contents = category prompt, schema =
    RecipeCategory) — both need the same overload fallback."""
    on_vercel = bool(os.environ.get("VERCEL"))
    if on_vercel:
        attempts = 1
    # ~30s + ~18s still leaves a little room under the 60s cap after
    # fetch, whether the primary model answers, is overloaded and falls
    # through to the fallback, or the fallback is tried too.
    model_attempts = [
        (settings.gemini_model, 30_000 if on_vercel else 170_000),
        (settings.gemini_fallback_model, 18_000 if on_vercel else 170_000),
    ]

    last_error: Exception | None = None
    for model_index, (model, timeout_ms) in enumerate(model_attempts):
        is_last_model = model_index == len(model_attempts) - 1
        for i in range(attempts):
            try:
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
            except Exception as exc:
                last_error = exc
                if gemini_is_quota_exhausted(exc) and i < attempts - 1:
                    delay = 2 ** (i + 1)
                    logger.warning("Gemini rate-limited; retrying in %ss", delay)
                    time.sleep(delay)
                    continue
                break
        if not is_last_model and gemini_is_busy(last_error):
            logger.warning("Gemini model %s is overloaded; falling back to %s", model, model_attempts[model_index + 1][0])
            continue
        raise last_error
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


def _parse_recipe(text: str) -> Recipe:
    try:
        return Recipe.model_validate_json(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end == -1:
            raise RuntimeError(f"Could not parse recipe JSON: {text[:400]}")
        return Recipe.model_validate(json.loads(text[start : end + 1]))
