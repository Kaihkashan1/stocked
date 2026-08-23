import json
import tempfile
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
    gemini_model: str = "gemini-3.6-flash"
    google_sheet_id: str = ""
    google_service_account_file: Path = ROOT / "service_account.json"
    google_service_account_json: str = ""
    recipe_box_secret: str = ""
    ntfy_topic: str = ""
    ytdlp_cookies_from_browser: str = ""
    ytdlp_cookies_file: str = ""
    ytdlp_cookies: str = ""

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

    def cookies_file_path(self) -> Path | None:
        raw_cookies = self.ytdlp_cookies.strip()
        if raw_cookies:
            path = Path(tempfile.gettempdir()) / "instagram_cookies.txt"
            if not path.exists() or path.read_text() != raw_cookies:
                path.write_text(raw_cookies)
            return path
        raw = self.ytdlp_cookies_file.strip()
        if not raw:
            return None
        path = Path(raw).expanduser()
        if not path.is_absolute():
            path = ROOT / path
        return path


settings = Settings()
