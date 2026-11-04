"""Persist original recipe photos on Google Drive.

The sheet only holds a Drive file id (the Photo column). Bytes live next
to the spreadsheet so they survive Vercel cold starts — /tmp does not.
The same service account that already edits the Sheet is used; gspread
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


class PhotoStoreError(RuntimeError):
    """Drive upload/download failed; the recipe should not pretend it kept the photo."""


@lru_cache(maxsize=1)
def _session() -> AuthorizedSession:
    creds = Credentials.from_service_account_info(settings.service_account_info(), scopes=DRIVE_SCOPES)
    return AuthorizedSession(creds)


@lru_cache(maxsize=1)
def _photos_folder_id() -> str:
    session = _session()
    parents = _spreadsheet_parents(session)
    parent_clause = ""
    if parents:
        parent_clause = " and ({})".format(" or ".join(f"'{pid}' in parents" for pid in parents))
    query = (
        f"name = '{PHOTOS_FOLDER_NAME}' and mimeType = 'application/vnd.google-apps.folder' "
        f"and trashed = false{parent_clause}"
    )
    response = session.get(
        FILES_URL,
        params={
            "q": query,
            "fields": "files(id)",
            "pageSize": 1,
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        },
        timeout=20,
    )
    if response.ok:
        files = response.json().get("files") or []
        if files:
            return files[0]["id"]
    metadata = {
        "name": PHOTOS_FOLDER_NAME,
        "mimeType": "application/vnd.google-apps.folder",
    }
    if parents:
        metadata["parents"] = [parents[0]]
    created = session.post(
        FILES_URL,
        params={"supportsAllDrives": "true"},
        json=metadata,
        timeout=20,
    )
    # Sharing only the spreadsheet (not its parent folder) is the usual
    # setup — in that case a sibling folder is forbidden, so fall back to
    # the service account's own Drive. The API can still serve those files.
    if not created.ok and "parents" in metadata:
        logger.warning("Could not create photos folder next to the sheet (%s); using the service account Drive", created.status_code)
        metadata.pop("parents", None)
        created = session.post(
            FILES_URL,
            params={"supportsAllDrives": "true"},
            json=metadata,
            timeout=20,
        )
    if not created.ok:
        raise PhotoStoreError(f"Could not create a photos folder ({created.status_code}).")
    folder_id = created.json().get("id")
    if not folder_id:
        raise PhotoStoreError("Could not create a photos folder.")
    logger.info("Created Drive folder %s for recipe photos", folder_id)
    return folder_id


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


def upload_recipe_photo(data: bytes, *, filename: str | None = None) -> str:
    if not data:
        raise PhotoStoreError("That photo was empty.")
    metadata = {
        "name": filename or f"recipe-{uuid.uuid4().hex}.jpg",
        "parents": [_photos_folder_id()],
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
