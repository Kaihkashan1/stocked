from __future__ import annotations

import logging
import tempfile
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from app import notify
from app.extract import extract_recipe
from app.fetch import extract_instagram_url, fetch_post
from app.store import save_recipe, source_exists

logger = logging.getLogger(__name__)

jobs: deque[dict] = deque(maxlen=30)


def process_recipe(raw_content: str) -> dict:
    url = None
    try:
        url = extract_instagram_url(raw_content)
        _record(url=url, status="started")
        if source_exists(url):
            logger.info("Already saved, skipping %s", url)
            _record(url=url, status="duplicate")
            notify.send("Recipe Box", f"Already saved:\n{url}")
            return {"status": "duplicate", "url": url, "message": "Already saved"}

        with tempfile.TemporaryDirectory(prefix="recipe-") as tmp:
            post = fetch_post(url, Path(tmp))
            recipe = extract_recipe(post)
            save_recipe(recipe, post)

        _record(url=url, status="saved", title=recipe.title, confidence=recipe.confidence)
        notify.send("Recipe saved", f"{recipe.title} ({recipe.confidence})")
        logger.info("Done: %s", recipe.title)
        return {
            "status": "saved",
            "url": url,
            "title": recipe.title,
            "confidence": recipe.confidence,
        }
    except Exception as exc:
        logger.exception("Failed to process recipe")
        _record(url=url, status="error", error=str(exc))
        notify.send("Recipe Box failed", str(exc)[:400])
        return {"status": "error", "url": url, "error": str(exc)}


def _record(**fields) -> None:
    jobs.appendleft({"at": datetime.now(timezone.utc).isoformat(), **fields})
