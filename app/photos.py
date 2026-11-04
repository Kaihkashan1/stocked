"""Persist original recipe photos on Google Drive.

The sheet only holds a Drive file id (the Photo column). Bytes live in
Drive so they survive Vercel cold starts — /tmp does not.

Service accounts have no Drive storage quota of their own. Sharing only
the spreadsheet is enough for recipe rows, but photos need a folder the
user owns (or a Shared Drive) that is also shared with the bot. The
same service account that already edits the Sheet is used; gspread
already requests the Drive scope.
"""
from __future__ import annotations

import json
import logging
import uuid
from functools import lru_cache

from google.auth.transport.requests import AuthorizedSession
from google.oauth2.service_account import Credentials

from app.config import settings

logger = logging.getLogger(__name__)

DRIVE_SCOPES = (
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive",
)
PHOTOS_FOLDER_NAME = "Recipe Box photos"
UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true"
FILES_URL = "https://www.googleapis.com/drive/v3/files"
FOLDER_FIELDS = "id,name,parents,driveId,owners(me,emailAddress),capabilities(canAddChildren)"


class PhotoStoreError(RuntimeError):
    """Drive upload/download failed; the recipe should not pretend it kept the photo."""


def _service_account_email() -> str:
    try:
        return str(settings.service_account_info().get("client_email") or "").strip()
    except Exception:
        return ""


def _share_folder_message() -> str:
    email = _service_account_email() or "the recipe-box service account"
    return (
        f'Share a Google Drive folder named “{PHOTOS_FOLDER_NAME}” with {email} '
        "as Editor (same email as the spreadsheet), then save again."
    )


def folder_uses_service_account_quota(folder: dict) -> bool:
    """True when files created here count against the bot's empty Drive quota."""
    if folder.get("driveId"):
        return False
    owners = folder.get("owners") or []
    if not owners:
        return False
    return all(bool(owner.get("me")) for owner in owners)


def pick_photos_folder(folders: list[dict]) -> dict | None:
    for folder in folders:
        capabilities = folder.get("capabilities") or {}
        if capabilities.get("canAddChildren") is False:
            continue
        if folder_uses_service_account_quota(folder):
            continue
        if folder.get("id"):
            return folder
    return None


@lru_cache(maxsize=1)
def _session() -> AuthorizedSession:
    creds = Credentials.from_service_account_info(settings.service_account_info(), scopes=DRIVE_SCOPES)
    return AuthorizedSession(creds)


def _list_files(session: AuthorizedSession, query: str, extra: dict | None = None) -> list[dict]:
    params = {
        "q": query,
        "fields": f"files({FOLDER_FIELDS})",
        "pageSize": 20,
        "supportsAllDrives": "true",
        "includeItemsFromAllDrives": "true",
        "corpora": "allDrives",
    }
    if extra:
        params.update(extra)
    response = session.get(FILES_URL, params=params, timeout=20)
    if not response.ok:
        logger.warning("Drive list failed (%s): %s", response.status_code, response.text[:200])
        return []
    return list(response.json().get("files") or [])


def _named_photo_folders(session: AuthorizedSession) -> list[dict]:
    return _list_files(
        session,
        f"name = '{PHOTOS_FOLDER_NAME}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
    )


def _spreadsheet_parents(session: AuthorizedSession) -> list[str]:
    sheet_id = settings.google_sheet_id
    if not sheet_id:
        return []
    response = session.get(
        f"{FILES_URL}/{sheet_id}",
        params={"fields": "parents", "supportsAllDrives": "true"},
        timeout=20,
    )
    if not response.ok:
        logger.warning("Could not read spreadsheet parents (%s)", response.status_code)
        return []
    return list(response.json().get("parents") or [])


def _shared_folder_parents(session: AuthorizedSession) -> list[str]:
    folders = _list_files(
        session,
        "mimeType = 'application/vnd.google-apps.folder' and trashed = false and sharedWithMe",
        extra={"corpora": "user"},
    )
    return [folder["id"] for folder in folders if folder.get("id") and not folder_uses_service_account_quota(folder)]


def _create_folder(session: AuthorizedSession, parent_id: str) -> str | None:
    created = session.post(
        FILES_URL,
        params={"supportsAllDrives": "true"},
        json={
            "name": PHOTOS_FOLDER_NAME,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent_id],
        },
        timeout=20,
    )
    if not created.ok:
        logger.warning("Could not create photos folder in %s (%s): %s", parent_id, created.status_code, created.text[:200])
        return None
    folder_id = created.json().get("id")
    return str(folder_id) if folder_id else None


@lru_cache(maxsize=1)
def _photos_folder_id() -> str:
    configured = settings.google_photos_folder_id.strip()
    if configured:
        return configured

    session = _session()
    existing = pick_photos_folder(_named_photo_folders(session))
    if existing:
        logger.info("Using Drive folder %s for recipe photos", existing["id"])
        return existing["id"]

    parent_ids = list(dict.fromkeys(_spreadsheet_parents(session) + _shared_folder_parents(session)))
    for parent_id in parent_ids:
        nested = pick_photos_folder(
            _list_files(
                session,
                f"name = '{PHOTOS_FOLDER_NAME}' and mimeType = 'application/vnd.google-apps.folder' "
                f"and trashed = false and '{parent_id}' in parents",
            )
        )
        if nested:
            return nested["id"]
        created_id = _create_folder(session, parent_id)
        if created_id:
            logger.info("Created Drive folder %s for recipe photos", created_id)
            return created_id

    raise PhotoStoreError(_share_folder_message())


def upload_recipe_photo(data: bytes, *, filename: str | None = None) -> str:
    if not data:
        raise PhotoStoreError("That photo was empty.")
    try:
        folder_id = _photos_folder_id()
    except PhotoStoreError:
        raise
    metadata = {
        "name": filename or f"recipe-{uuid.uuid4().hex}.jpg",
        "parents": [folder_id],
        "mimeType": "image/jpeg",
    }
    metadata_part = json.dumps(metadata).encode("utf-8")
    body = (
        b"--recipebox\r\n"
        b"Content-Type: application/json; charset=UTF-8\r\n\r\n"
        + metadata_part
        + b"\r\n--recipebox\r\n"
        b"Content-Type: image/jpeg\r\n\r\n"
        + data
        + b"\r\n--recipebox--"
    )
    response = _session().post(
        UPLOAD_URL,
        headers={"Content-Type": "multipart/related; boundary=recipebox"},
        data=body,
        timeout=60,
    )
    if not response.ok:
        logger.error("Drive photo upload failed: %s %s", response.status_code, response.text[:300])
        _photos_folder_id.cache_clear()
        if response.status_code == 403 and "storage quota" in response.text.lower():
            raise PhotoStoreError(_share_folder_message())
        raise PhotoStoreError("Could not keep that photo. Try again.")
    file_id = response.json().get("id")
    if not file_id:
        raise PhotoStoreError("Could not keep that photo. Try again.")
    return file_id


def download_recipe_photo(file_id: str) -> tuple[bytes, str]:
    response = _session().get(
        f"{FILES_URL}/{file_id}",
        params={"alt": "media", "supportsAllDrives": "true"},
        timeout=60,
    )
    if response.status_code == 404:
        raise FileNotFoundError(file_id)
    if not response.ok:
        logger.error("Drive photo download failed: %s", response.status_code)
        raise PhotoStoreError("Could not load that photo.")
    content_type = response.headers.get("Content-Type") or "image/jpeg"
    return response.content, content_type.split(";")[0].strip()


def delete_recipe_photo(file_id: str) -> None:
    if not file_id:
        return
    response = _session().delete(
        f"{FILES_URL}/{file_id}",
        params={"supportsAllDrives": "true"},
        timeout=20,
    )
    if response.status_code not in (200, 204, 404):
        logger.warning("Drive photo delete failed for %s: %s", file_id, response.status_code)
