"""Turns a raw exception into the same user-facing message everywhere it can
happen, instead of each call site inventing its own wording or leaking a bare
status code / raw API error dump. Used by both the /ingest pipeline (link
saves) and the /api/extract-photo endpoint (photo saves) so a Gemini quota
hit or an Apify limit reads the same way no matter which path triggered it.
"""

from __future__ import annotations

import httpx
from google.genai.errors import APIError as GeminiAPIError

from app.config import settings
from app.fetch import ApifyLimitError

# The free tier's actual daily cap, per API key/project. Kept as one
# constant so the wording below and the Settings "API usage" card (see
# app.store.get_gemini_reads_today) can never drift apart. Doubles
# automatically when GEMINI_API_KEY_2 is set — see app.extract's per-key
# fallback, which is what actually makes the higher number true.
_GEMINI_KEYS_CONFIGURED = 2 if settings.gemini_api_key_2.strip() else 1
GEMINI_DAILY_QUOTA = 20 * _GEMINI_KEYS_CONFIGURED

_quota_note = (
    f"{GEMINI_DAILY_QUOTA} requests/day across 2 keys"
    if _GEMINI_KEYS_CONFIGURED > 1
    else f"{GEMINI_DAILY_QUOTA} requests/day"
)
GEMINI_QUOTA_MESSAGE = (
    f"Gemini's daily quota ({_quota_note}) is used up. "
    "Try again after it resets around 9 am CET."
)

GEMINI_BUSY_MESSAGE = (
    "Gemini is busy right now. Wait a few seconds and try again."
)


def gemini_is_busy(exc: Exception) -> bool:
    """Capacity blips (503 / 'high demand' / 504 DEADLINE_EXCEEDED), not the
    daily free-tier cap.

    A client-side timeout (see app.extract's explicit HttpOptions.timeout)
    counts too: the SDK has no timeout of its own, so without ours a slow
    Gemini response would just run out the clock until Vercel's hard 60s
    kill instead of failing cleanly — and a response that takes that long
    reads the same as "busy" from here, whether Gemini ever answered or not.

    504 is Gemini's own server-side deadline, not ours — seen live as
    "DEADLINE_EXCEEDED. ... Deadline expired before operation could
    complete." when the model itself is currently slow to respond."""
    if isinstance(exc, httpx.TimeoutException):
        return True
    code = getattr(exc, "code", None)
    if code in (500, 503, 504):
        return True
    message = str(getattr(exc, "message", None) or exc).lower()
    return (
        "high demand" in message
        or "unavailable" in message
        or "overloaded" in message
        or "try again later" in message
        or "timeout" in message
        or "timed out" in message
        or "deadline_exceeded" in message
        or "deadline expired" in message
    )


def gemini_is_quota_exhausted(exc: Exception) -> bool:
    """A real daily-cap 429 (RESOURCE_EXHAUSTED) — distinct from
    gemini_is_busy's capacity blips, which a fresh key wouldn't fix but a
    fresh day (or a second key, see app.extract) would."""
    return isinstance(exc, GeminiAPIError) and exc.code == 429 and not gemini_is_busy(exc)


def gemini_is_retryable(exc: Exception) -> bool:
    if gemini_is_busy(exc):
        return True
    code = getattr(exc, "code", None)
    if code == 429:
        return True
    message = str(exc).lower()
    return "429" in message or "resource_exhausted" in message


def friendly_message(exc: Exception) -> str:
    if isinstance(exc, GeminiAPIError) and exc.code == 429:
        return GEMINI_QUOTA_MESSAGE
    if gemini_is_busy(exc):
        return GEMINI_BUSY_MESSAGE
    if isinstance(exc, ApifyLimitError):
        return str(exc)
    return str(exc)
