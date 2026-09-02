import json
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    gemini_api_key: str = ""
    # Optional — a second Google account's own API key. The free tier's
    # 20/day cap is per key/project, so once the first is exhausted,
    # app.extract falls back to this one instead of failing for the rest
    # of the day. Leave unset to keep using just one key.
    gemini_api_key_2: str = ""
    gemini_model: str = "gemini-3.6-flash"
    google_sheet_id: str = ""
    google_service_account_file: Path = ROOT / "service_account.json"
    google_service_account_json: str = ""
    recipe_box_secret: str = ""
    ntfy_topic: str = ""
    # Instagram fetches go through this actor — no login, no personal
    # cookies, no risk to any Instagram account. Required for Instagram
    # links; there is no cookie-based fallback. See README for setup.
    apify_api_token: str = ""
    apify_instagram_actor: str = "apify~instagram-post-scraper"
    # Fallback used only when the primary actor's own handful of comments
    # doesn't include the post owner's — a dedicated comments-mode search
    # over more (up to 15 free) comments, sorted newest first. See
    # fetch.py's _pick_comment_text / _fetch_more_comments for why this
    # exists (a real gap this actor's own limited comment sample missed).
    apify_comments_actor: str = "apify~instagram-scraper"

    def has_service_account(self) -> bool:
        return bool(self.google_service_account_json.strip()) or self.google_service_account_file.exists()

    def service_account_info(self) -> dict:
        raw = self.google_service_account_json.strip()
        if raw:
            return json.loads(raw)
        path = self.google_service_account_file
        if not path.exists():
            raise RuntimeError(
                f"Service account file missing at {path}. "
                "Set GOOGLE_SERVICE_ACCOUNT_JSON on Vercel, or save the JSON key locally (see README)."
            )
        return json.loads(path.read_text())


settings = Settings()
