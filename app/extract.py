from __future__ import annotations

import json
import logging
import time
from pathlib import Path

from google import genai
from google.genai import types

from app.config import settings
from app.models import FetchedPost, Recipe, RecipeCategory

logger = logging.getLogger(__name__)

PROMPT = """Extract exactly one recipe from this saved recipe content.

If a video and/or image is attached, watch/look at it alongside the text below —
prefer spoken instructions and on-screen text over the text if they disagree.
If nothing is attached, the text below is the full source (a caption, or the
text of a recipe blog page): read it directly.

Rules:
- Quantities and units should be as specific as the content allows. Use "" if unknown.
- Steps should be a cook-along list, one action per item, in order.
- cuisine: a short regional label such as Indian, Italian, Mexican, East Asian, Middle Eastern, or American. Use Other only if it truly has no regional identity.
- meal: breakfast, lunch, dinner, snack, dessert, drink, or other.
- time: total time if mentioned (for example "30 min"), otherwise null.
- tags: up to 5 short lowercase tags such as vegetarian, vegan, spicy, weeknight, rice, one-pot.
- If this is not a recipe, still return JSON with a short title, empty lists, confidence "low", and meal "other".
- Return JSON only, matching the schema. No markdown.

TEXT:
{caption}
"""

CATEGORY_PROMPT = """Categorize this saved recipe.

cuisine: a short label such as Indian, Italian, Mexican, East Asian, Middle Eastern, American, or Other.
meal: breakfast, lunch, dinner, snack, dessert, drink, or other.
time: total time if mentioned, otherwise null.
tags: up to 5 short lowercase tags (vegetarian, vegan, spicy, weeknight, rice, one-pot, ...).

TITLE: {title}
SERVINGS: {servings}
INGREDIENTS:
{ingredients}
STEPS:
{steps}
CAPTION:
{caption}
"""


def extract_recipe(post: FetchedPost) -> Recipe:
    if not settings.gemini_api_key:
        raise RuntimeError("GEMINI_API_KEY is missing. Add it to .env (see README).")

    client = genai.Client(api_key=settings.gemini_api_key)
    media_path = post.video_path or post.thumbnail_path
    uploaded = None
    try:
        contents: list = []
        if media_path:
            uploaded = _upload_and_wait(client, Path(media_path))
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
    last_error: Exception | None = None
    for i in range(attempts):
        try:
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
            message = str(exc)
            rate_limited = "429" in message or "RESOURCE_EXHAUSTED" in message
            if rate_limited and i < attempts - 1:
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
