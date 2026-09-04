from __future__ import annotations

import logging
import tempfile
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from app import notify
from app.errors import friendly_message
from app.extract import extract_recipe
from app.fetch import extract_url, fetch_post
from app.store import log_import, save_recipe, source_exists

logger = logging.getLogger(__name__)

jobs: deque[dict] = deque(maxlen=30)


def process_recipe(raw_content: str) -> dict:
    url = None
    used_backup = False
    try:
        url = extract_url(raw_content)
        _record(url=url, status="started")
        if source_exists(url):
            logger.info("Already saved, skipping %s", url)
            _record(url=url, status="duplicate")
            notify.send("Recipe Box", f"Already saved:\n{url}")
            return {"status": "duplicate", "url": url, "message": "Already saved"}

        with tempfile.TemporaryDirectory(prefix="recipe-") as tmp:
            post = fetch_post(url, Path(tmp))
            recipes, used_backup = extract_recipe(post)
            if not recipes:
                raise RuntimeError("Gemini returned no recipes.")
            for recipe in recipes:
                save_recipe(recipe, post)

        first = recipes[0]
        extra = len(recipes) - 1
        title = first.title if extra == 0 else f"{first.title} (+{extra} more)"
        _record(url=url, status="saved", title=title, confidence=first.confidence, used_backup=used_backup)
        notify.send("Recipe saved", f"{title} ({first.confidence})")
        logger.info("Done: %s", title)
        return {
            "status": "saved",
            "url": url,
            "title": title,
            "confidence": first.confidence,
        }
    except Exception as exc:
        logger.exception("Failed to process recipe")
        message = friendly_message(exc)
        _record(
            url=url,
            status="error",
            error=message,
            used_backup=bool(getattr(exc, "used_backup", used_backup)),
        )
        notify.send("Recipe Box failed", message[:400])
        return {
            "status": "error",
            "url": url,
            "error": message,
            "message": message,
        }


def _record(**fields) -> None:
    jobs.appendleft({"at": datetime.now(timezone.utc).isoformat(), **fields})
    status = fields.get("status")
    if status == "started":
        return
    url = fields.get("url")
    used_backup = bool(fields.get("used_backup"))
    if status == "duplicate":
        reason = "Already saved"
    elif status == "saved":
        title = fields.get("title") or "Recipe"
        confidence = fields.get("confidence") or ""
        reason = f"{title} ({confidence})" if confidence else str(title)
    else:
        reason = fields.get("error") or "Import failed"
    log_import(url, status or "error", reason, used_backup=used_backup)
