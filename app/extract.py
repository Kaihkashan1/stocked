from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

from google import genai
from google.genai import types

from app.config import settings
from app.errors import gemini_is_retryable
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


def extract_recipe(post: FetchedPost) -> Recipe:
    if not settings.gemini_api_key:
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    # The SDK's default client has no per-call timeout at all (it waits on
    # the underlying HTTP request indefinitely) — so a single slow Gemini
    # response doesn't fail, it just runs out the clock until Vercel's hard
    # 60s kill, which surfaces as an opaque FUNCTION_INVOCATION_TIMEOUT with
    # no friendly message and no chance for _generate_with_retry to react.
    # A shorter, explicit timeout turns that into a normal (retryable, or at
    # least cleanly reported) exception well before the platform gives up.
    call_timeout_ms = 25_000 if os.environ.get("VERCEL") else 170_000
    client = genai.Client(
        api_key=settings.gemini_api_key,
        http_options=types.HttpOptions(timeout=call_timeout_ms),
    )
    media_path = post.video_path or post.thumbnail_path
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
        contents.append(PROMPT.format(caption=post.caption or "(no caption)"))
        text = _generate_with_retry(client, contents)
        return _parse_recipe(text)
    finally:
        if uploaded is not None:
            try:
                client.files.delete(name=uploaded.name)
            except Exception:
                logger.debug("Could not delete Gemini file %s", uploaded.name)


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


def _generate_with_retry(client: genai.Client, contents: list, attempts: int = 3) -> str:
    """A couple of short retries for 429 / high-demand blips. Kept brief so
    the whole photo-extract still fits inside Vercel's 60s function cap.
    Each attempt is a real Gemini request and is counted, including ones
    that fail — that's what the free-tier daily cap bills."""
    last_error: Exception | None = None
    if os.environ.get("VERCEL"):
        attempts = min(attempts, 2)
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
            if gemini_is_retryable(exc) and i < attempts - 1:
                delay = 2 * (i + 1)
                logger.warning("Gemini busy or rate-limited; retrying in %ss", delay)
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
