"""Turns a raw exception into the same user-facing message everywhere it can
happen, instead of each call site inventing its own wording or leaking a bare
status code / raw API error dump. Used by both the /ingest pipeline (link
saves) and the /api/extract-photo endpoint (photo saves) so a Gemini quota
hit or an Apify limit reads the same way no matter which path triggered it.
"""

from __future__ import annotations

from google.genai.errors import APIError as GeminiAPIError

from app.fetch import ApifyLimitError

GEMINI_QUOTA_MESSAGE = (
    "Gemini's free daily quota (20 requests/day) is used up. "
    "Try again after it resets — usually around midnight Pacific time."
)


def friendly_message(exc: Exception) -> str:
    if isinstance(exc, GeminiAPIError) and exc.code == 429:
        return GEMINI_QUOTA_MESSAGE
    if isinstance(exc, ApifyLimitError):
        return str(exc)
    return str(exc)
