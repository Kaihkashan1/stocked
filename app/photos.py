"""Persist original recipe photos.

Prefer a user-owned Drive folder (service accounts have no storage of
their own). If that is not available, keep the bytes in a Photos tab of
the same spreadsheet the recipes already live in — that file is owned
by you, so it works from the phone or Vercel without this Mac.
"""
from __future__ import annotations

import base64
import json
import logging
import uuid
from functools import lru_cache
from pathlib import Path

from google.auth.transport.requests import AuthorizedSession
from google.oauth2.service_account import Credentials

from app.config import ROOT, settings

logger = logging.getLogger(__name__)

DRIVE_SCOPES = (
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive",
)
PHOTOS_FOLDER_NAME = "Recipe Box photos"
UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true"
FILES_URL = "https://www.googleapis.com/drive/v3/files"
FOLDER_FIELDS = "id,name,parents,driveId,owners(me,emailAddress),capabilities(canAddChildren)"
LOCAL_PREFIX = "local:"
SHEET_PREFIX = "sheet:"
LOCAL_DIR = ROOT / "data" / "photos"
PHOTOS_SHEET_TITLE = "Photos"
PHOTOS_SHEET_HEADERS = ["id", "content_type", "part", "data"]
# Stay under Sheets' 50k character cell limit, and write a few rows at a
# time so one photo cannot blow the API request size cap.
SHEET_CELL_CHARS = 45_000
SHEET_WRITE_BATCH = 8


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


def is_local_photo_id(file_id: str) -> bool:
    return str(file_id or "").startswith(LOCAL_PREFIX)


def is_sheet_photo_id(file_id: str) -> bool:
    return str(file_id or "").startswith(SHEET_PREFIX)


def _local_path(file_id: str) -> Path:
    name = Path(str(file_id)[len(LOCAL_PREFIX) :]).name
    if not name or name.startswith("."):
        raise FileNotFoundError(file_id)
    return LOCAL_DIR / name


def _sheet_photo_key(file_id: str) -> str:
    key = str(file_id)[len(SHEET_PREFIX) :].strip()
    if not key:
        raise FileNotFoundError(file_id)
    return key


@lru_cache(maxsize=1)
def _photos_worksheet():
    import gspread
    from app.store import _worksheet, retry_sheets_call

    spreadsheet = _worksheet().spreadsheet
    try:
        worksheet = retry_sheets_call(lambda: spreadsheet.worksheet(PHOTOS_SHEET_TITLE))
    except gspread.WorksheetNotFound:
        worksheet = retry_sheets_call(
            lambda: spreadsheet.add_worksheet(title=PHOTOS_SHEET_TITLE, rows=2, cols=len(PHOTOS_SHEET_HEADERS))
        )
        retry_sheets_call(lambda: worksheet.update("A1:D1", [PHOTOS_SHEET_HEADERS], value_input_option="RAW"))
        return worksheet
    if worksheet.col_count < len(PHOTOS_SHEET_HEADERS):
        retry_sheets_call(
            lambda: worksheet.resize(rows=max(worksheet.row_count, 2), cols=len(PHOTOS_SHEET_HEADERS))
        )
    return worksheet


def _upload_sheet(data: bytes, filename: str | None = None) -> str:
    from app.store import retry_sheets_call

    photo_id = uuid.uuid4().hex
    encoded = base64.b64encode(data).decode("ascii")
    chunks = [encoded[i : i + SHEET_CELL_CHARS] for i in range(0, len(encoded), SHEET_CELL_CHARS)] or [""]
    worksheet = _photos_worksheet()
    start = max(len(retry_sheets_call(lambda: worksheet.col_values(1))) + 1, 2)
    rows = [[photo_id, "image/jpeg", str(index), chunk] for index, chunk in enumerate(chunks)]
    needed = start + len(rows) - 1
    if worksheet.row_count < needed:
        retry_sheets_call(lambda: worksheet.resize(rows=needed, cols=max(worksheet.col_count, len(PHOTOS_SHEET_HEADERS))))
    for offset in range(0, len(rows), SHEET_WRITE_BATCH):
        batch = rows[offset : offset + SHEET_WRITE_BATCH]
        first = start + offset
        last = first + len(batch) - 1
        retry_sheets_call(
            lambda batch=batch, first=first, last=last: worksheet.update(
                f"A{first}:D{last}", batch, value_input_option="RAW"
            )
        )
    logger.info("Kept recipe photo in the spreadsheet (%s, %s chunks)", filename or photo_id, len(chunks))
    return f"{SHEET_PREFIX}{photo_id}"


def _download_sheet(file_id: str) -> tuple[bytes, str]:
    key = _sheet_photo_key(file_id)
    values = _photos_worksheet().get_all_values()
    parts: list[tuple[int, str]] = []
    content_type = "image/jpeg"
    for row in values[1:]:
        if not row or row[0] != key:
            continue
        content_type = (row[1] if len(row) > 1 else "") or content_type
        try:
            index = int(row[2]) if len(row) > 2 else 0
        except ValueError:
            index = 0
        parts.append((index, row[3] if len(row) > 3 else ""))
    if not parts:
        raise FileNotFoundError(file_id)
    parts.sort()
    try:
        return base64.b64decode("".join(chunk for _, chunk in parts)), content_type
    except Exception as exc:
        raise PhotoStoreError("Could not load that photo.") from exc


def _delete_sheet(file_id: str) -> None:
    key = _sheet_photo_key(file_id)
    worksheet = _photos_worksheet()
    values = worksheet.get_all_values()
    rows = [index for index, row in enumerate(values, start=1) if index > 1 and row and row[0] == key]
    for index in reversed(rows):
        worksheet.delete_rows(index)


def _upload_drive(data: bytes, filename: str | None) -> str:
    folder_id = _photos_folder_id()
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


def upload_recipe_photo(data: bytes, *, filename: str | None = None) -> str:
    if not data:
        raise PhotoStoreError("That photo was empty.")
    if settings.google_photos_folder_id.strip():
        try:
            return _upload_drive(data, filename)
        except PhotoStoreError:
            logger.warning("Google Drive cannot store the photo; keeping it in the spreadsheet instead")
        except Exception:
            logger.exception("Google Drive photo upload failed; keeping it in the spreadsheet instead")
    try:
        return _upload_sheet(data, filename)
    except PhotoStoreError:
        raise
    except Exception as exc:
        logger.exception("Spreadsheet photo upload failed")
        raise PhotoStoreError("Could not keep that photo. Try again.") from exc


def download_recipe_photo(file_id: str) -> tuple[bytes, str]:
    if is_local_photo_id(file_id):
        path = _local_path(file_id)
        if not path.is_file():
            raise FileNotFoundError(file_id)
        return path.read_bytes(), "image/jpeg"
    if is_sheet_photo_id(file_id):
        return _download_sheet(file_id)
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
    if is_local_photo_id(file_id):
        path = _local_path(file_id)
        path.unlink(missing_ok=True)
        return
    if is_sheet_photo_id(file_id):
        _delete_sheet(file_id)
        return
    response = _session().delete(
        f"{FILES_URL}/{file_id}",
        params={"supportsAllDrives": "true"},
        timeout=20,
    )
    if response.status_code not in (200, 204, 404):
        logger.warning("Drive photo delete failed for %s: %s", file_id, response.status_code)
