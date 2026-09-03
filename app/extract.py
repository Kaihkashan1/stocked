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


def extract_recipe(post: FetchedPost) -> Recipe:
    keys = _gemini_api_keys()
    if not keys:
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    # One generate_content wait. A short timeout + retry was billing two
    # requests for saves that used to finish in a single slower call.
    # ~50s on Vercel still leaves a little room under the 60s function cap
    # after fetch; locally we can wait much longer.
    call_timeout_ms = 50_000 if os.environ.get("VERCEL") else 170_000
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
            text = _generate_with_retry(client, contents)
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


def _generate_with_retry(client: genai.Client, contents: list, attempts: int = 5) -> str:
    """One generate_content per import on Vercel (busy/timeouts are not
    retried — those retries were billing twice). Locally, a daily-quota
    429 can retry on the same key before extract_recipe tries the next."""
    last_error: Exception | None = None
    if os.environ.get("VERCEL"):
        attempts = 1
    for i in range(attempts):
        try:
            record_gemini_read()
            response = client.models.generate_content(
                model=settings.gemini_model,
                contents=contents,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_schema=Recipe,
                    thinking_config=types.ThinkingConfig(
                        thinking_level=types.ThinkingLevel.MINIMAL,
                    ),
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

    client = genai.Client(api_key=settings.gemini_api_key)
    prompt = CATEGORY_PROMPT.format(
        title=title or "(untitled)",
        servings=servings or "",
        ingredients=ingredients or "(none)",
        steps=steps or "(none)",
        caption=caption or "(none)",
    )
    record_gemini_read()
    response = client.models.generate_content(
        model=settings.gemini_model,
        contents=prompt,
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=RecipeCategory,
            thinking_config=types.ThinkingConfig(
                thinking_level=types.ThinkingLevel.MINIMAL,
            ),
        ),
    )
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty category response.")
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
