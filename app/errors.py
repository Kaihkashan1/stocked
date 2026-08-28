"""Turns a raw exception into the same user-facing message everywhere it can
happen, instead of each call site inventing its own wording or leaking a bare
status code / raw API error dump. Used by both the /ingest pipeline (link
saves) and the /api/extract-photo endpoint (photo saves) so a Gemini quota
hit or an Apify limit reads the same way no matter which path triggered it.
"""

from __future__ import annotations

from google.genai.errors import APIError as GeminiAPIError

from app.fetch import ApifyLimitError

# The free tier's actual daily cap. Kept as one constant so the wording
# below and the Settings "API usage" card (see app.store.get_gemini_reads_today)
# can never drift apart.
GEMINI_DAILY_QUOTA = 20

GEMINI_QUOTA_MESSAGE = (
    f"Gemini's free daily quota ({GEMINI_DAILY_QUOTA} requests/day) is used up. "
    "Try again after it resets — usually around midnight Pacific time."
)


def friendly_message(exc: Exception) -> str:
    if isinstance(exc, GeminiAPIError) and exc.code == 429:
        return GEMINI_QUOTA_MESSAGE
    if isinstance(exc, ApifyLimitError):
        return str(exc)
    return str(exc)
