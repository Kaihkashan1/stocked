from __future__ import annotations

import unittest

from app.photos import folder_uses_service_account_quota, pick_photos_folder


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
