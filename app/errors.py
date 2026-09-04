"""Turns a raw exception into the same user-facing message everywhere it can
happen, instead of each call site inventing its own wording or leaking a bare
status code / raw API error dump. Used by both the /ingest pipeline (link
saves) and the /api/extract-photo endpoint (photo saves) so a Gemini quota
hit or an Apify limit reads the same way no matter which path triggered it.
"""

from __future__ import annotations

import httpx
from google.genai.errors import APIError as GeminiAPIError

from app.fetch import ApifyLimitError

# Primary free-tier daily cap, plus the fallback model's own (much higher)
# cap. Combined for the quota-exhausted error and the Settings "Imports today"
# bar. Used is still the self-tracked Gemini call count for today.
GEMINI_PRIMARY_DAILY_QUOTA = 20
GEMINI_FALLBACK_DAILY_QUOTA = 500
GEMINI_DAILY_QUOTA = GEMINI_PRIMARY_DAILY_QUOTA + GEMINI_FALLBACK_DAILY_QUOTA

GEMINI_QUOTA_MESSAGE = (
    f"Gemini's daily quota ({GEMINI_DAILY_QUOTA} requests/day) is used up. "
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
    gemini_is_busy's capacity blips."""
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
