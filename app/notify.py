from __future__ import annotations

import logging

import httpx

from app.config import settings

logger = logging.getLogger(__name__)


def send(title: str, message: str) -> None:
    topic = settings.ntfy_topic.strip()
    if not topic:
        return
    try:
        httpx.post(
            f"https://ntfy.sh/{topic}",
            content=message.encode("utf-8"),
            headers={"Title": title, "Tags": "cooking"},
            timeout=10,
        )
    except Exception:
        logger.exception("Failed to send ntfy notification")
