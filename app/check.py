"""Sanity-check local setup without ingesting a recipe.

Run:  python -m app.check
"""

from __future__ import annotations

from app.config import ROOT, settings


def main() -> int:
    errors: list[str] = []
    print(f"Project root: {ROOT}")

    if not settings.gemini_api_key:
        errors.append("GEMINI_API_KEY is empty")
    else:
        print("Gemini API key: set")

    print(f"Gemini model: {settings.gemini_model}")

    if not settings.google_sheet_id:
        errors.append("GOOGLE_SHEET_ID is empty")
    else:
        print(f"Sheet id: {settings.google_sheet_id[:8]}…")

    if settings.google_service_account_json.strip():
        print("Service account: GOOGLE_SERVICE_ACCOUNT_JSON")
    elif settings.google_service_account_file.exists():
        print(f"Service account: {settings.google_service_account_file}")
    else:
        errors.append(
            f"Service account missing: {settings.google_service_account_file} "
            "(or set GOOGLE_SERVICE_ACCOUNT_JSON)"
        )

    if settings.recipe_box_secret in ("", "change-me"):
        print("Warning: RECIPE_BOX_SECRET is still the placeholder — fine for LAN testing")
    else:
        print("Shared secret: set")

    cookie_file = settings.cookies_file_path()
    if cookie_file:
        if cookie_file.exists() and cookie_file.stat().st_size > 0:
            print(f"yt-dlp cookies file: {cookie_file}")
        else:
            errors.append(
                f"Cookies file missing or empty: {cookie_file}. "
                "Export Instagram-only cookies there (see README)."
            )
    elif settings.ytdlp_cookies_from_browser:
        print(f"yt-dlp cookies: browser={settings.ytdlp_cookies_from_browser}")
    else:
        print("yt-dlp cookies: none (Instagram downloads will probably fail)")

    if errors:
        print("\nNot ready yet:")
        for item in errors:
            print(f"  - {item}")
        print("\nFollow README.md to finish setup, then run this again.")
        return 1

    try:
        from google import genai

        client = genai.Client(api_key=settings.gemini_api_key)
        client.models.generate_content(model=settings.gemini_model, contents="Reply with the single word pong.")
        print("Gemini: reachable")
    except Exception as exc:
        errors.append(f"Gemini call failed: {exc}")

    try:
        from app.store import _worksheet

        _worksheet.cache_clear()
        ws = _worksheet()
        print(f"Google Sheet: opened {ws.spreadsheet.title!r} / {ws.title!r}")
    except Exception as exc:
        detail = str(exc).strip() or f"{type(exc).__name__} (no message)"
        errors.append(f"Sheets call failed: {detail}")

    if errors:
        print("\nChecks failed:")
        for item in errors:
            print(f"  - {item}")
        return 1

    print("\nAll checks passed. Start the server with:")
    print("  .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
