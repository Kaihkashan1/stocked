from __future__ import annotations

import base64
import unittest
from unittest.mock import patch

from app.photos import (
    PhotoStoreError,
    SHEET_CELL_CHARS,
    delete_recipe_photo,
    download_recipe_photo,
    folder_uses_service_account_quota,
    pick_photos_folder,
    upload_recipe_photo,
)
from app.store import retry_sheets_call


class PhotoFolderPickerTests(unittest.TestCase):
    def test_skips_service_account_owned_folder(self):
        sa_folder = {
            "id": "sa",
            "owners": [{"me": True, "emailAddress": "bot@example.com"}],
            "capabilities": {"canAddChildren": True},
        }
        self.assertTrue(folder_uses_service_account_quota(sa_folder))
        self.assertIsNone(pick_photos_folder([sa_folder]))

    def test_prefers_user_owned_shared_folder(self):
        sa_folder = {
            "id": "sa",
            "owners": [{"me": True}],
            "capabilities": {"canAddChildren": True},
        }
        user_folder = {
            "id": "user",
            "owners": [{"me": False, "emailAddress": "kai@example.com"}],
            "capabilities": {"canAddChildren": True},
        }
        picked = pick_photos_folder([sa_folder, user_folder])
        self.assertEqual(picked["id"], "user")

    def test_shared_drive_folder_is_usable(self):
        folder = {
            "id": "shared",
            "driveId": "drive",
            "owners": [{"me": True}],
            "capabilities": {"canAddChildren": True},
        }
        self.assertFalse(folder_uses_service_account_quota(folder))
        self.assertEqual(pick_photos_folder([folder])["id"], "shared")


class FakePhotosSheet:
    def __init__(self):
        self.rows = [["id", "content_type", "part", "data"]]

    @property
    def row_count(self):
        return len(self.rows)

    @property
    def col_count(self):
        return 4

    def resize(self, rows=None, cols=None):
        while len(self.rows) < (rows or 0):
            self.rows.append(["", "", "", ""])

    def col_values(self, _index):
        return [row[0] for row in self.rows]

    def get_all_values(self):
        return [list(row) for row in self.rows]

    def update(self, range_name, values, value_input_option="RAW"):
        start = int(range_name.split("A")[1].split(":")[0])
        while len(self.rows) < start - 1 + len(values):
            self.rows.append(["", "", "", ""])
        for offset, row in enumerate(values):
            self.rows[start - 1 + offset] = list(row)

    def delete_rows(self, index):
        del self.rows[index - 1]


class SheetPhotoFallbackTests(unittest.TestCase):
    def test_keeps_photo_in_the_spreadsheet_when_drive_is_unavailable(self):
        sheet = FakePhotosSheet()
        payload = b"jpeg-bytes" * 20
        with (
            patch("app.photos._photos_worksheet", return_value=sheet),
            patch("app.photos._upload_drive", side_effect=PhotoStoreError("share a folder")),
        ):
            photo_id = upload_recipe_photo(payload, filename="curry.jpg")
            data, content_type = download_recipe_photo(photo_id)
            self.assertTrue(photo_id.startswith("sheet:"))
            self.assertEqual(data, payload)
            self.assertEqual(content_type, "image/jpeg")
            delete_recipe_photo(photo_id)
            self.assertEqual(sheet.rows, [["id", "content_type", "part", "data"]])

    def test_splits_large_photos_across_cells(self):
        sheet = FakePhotosSheet()
        payload = b"\xff" * (SHEET_CELL_CHARS + 50)
        with (
            patch("app.photos._photos_worksheet", return_value=sheet),
            patch("app.photos._upload_drive", side_effect=PhotoStoreError("share a folder")),
        ):
            photo_id = upload_recipe_photo(payload)
            encoded = base64.b64encode(payload).decode("ascii")
            self.assertGreater(len(sheet.rows), 2)
            self.assertEqual(download_recipe_photo(photo_id)[0], payload)
            self.assertEqual("".join(row[3] for row in sheet.rows[1:]), encoded)

    def test_spreadsheet_errors_become_photo_store_errors(self):
        with (
            patch("app.photos.settings.google_photos_folder_id", ""),
            patch("app.photos._upload_sheet", side_effect=RuntimeError("Sheets 500")),
        ):
            with self.assertRaises(PhotoStoreError):
                upload_recipe_photo(b"jpeg-bytes")


class SheetsRetryTests(unittest.TestCase):
    def test_retries_transient_failures_then_succeeds(self):
        calls = {"n": 0}

        def flaky():
            calls["n"] += 1
            if calls["n"] < 3:
                raise RuntimeError("500 Internal Error")
            return "ok"

        with patch("app.store.time.sleep"):
            self.assertEqual(retry_sheets_call(flaky, attempts=4, delay=0), "ok")
        self.assertEqual(calls["n"], 3)
