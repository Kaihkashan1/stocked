from __future__ import annotations

import unittest

from app.store import is_photo_source, public_photo_source, stored_photo_source


class PhotoSourceTests(unittest.TestCase):
    def test_accepts_client_and_sheet_sentinels(self):
        self.assertTrue(is_photo_source("(photo)"))
        self.assertTrue(is_photo_source("photo"))
        self.assertTrue(is_photo_source("#NAME?"))
        self.assertFalse(is_photo_source(""))
        self.assertFalse(is_photo_source("https://example.com"))

    def test_stores_bare_word_so_sheets_does_not_parse_a_formula(self):
        self.assertEqual(stored_photo_source("(photo)"), "photo")
        self.assertEqual(stored_photo_source("", has_photo=True), "photo")
        self.assertEqual(stored_photo_source(""), "")

    def test_api_still_returns_the_client_sentinel(self):
        self.assertEqual(public_photo_source("photo"), "(photo)")
        self.assertEqual(public_photo_source("", "drive-file-id"), "(photo)")
        self.assertEqual(public_photo_source("https://instagram.com/p/x"), "https://instagram.com/p/x")
