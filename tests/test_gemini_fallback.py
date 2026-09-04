from unittest import TestCase
from unittest.mock import patch

from google.genai.errors import APIError as GeminiAPIError

from app.extract import _generate_with_retry


class GenerateWithRetryTests(TestCase):
    def setUp(self):
        settings_patch = patch("app.extract.settings")
        self.settings = settings_patch.start()
        self.addCleanup(settings_patch.stop)
        self.settings.gemini_model = "gemini-3.6-flash"
        self.settings.gemini_fallback_model = "gemini-3.5-flash-lite"

        once_patch = patch("app.extract._generate_once")
        self.once = once_patch.start()
        self.addCleanup(once_patch.stop)

        self.client = object()
        self.schema = object()

    def _call(self):
        return _generate_with_retry(self.client, "contents", self.schema, timeout_ms=1000)

    def test_falls_back_when_primary_is_busy(self):
        busy = GeminiAPIError(503, {"error": {"message": "high demand"}})
        self.once.side_effect = [busy, '{"ok": true}']
        text, used_backup = self._call()
        self.assertEqual(text, '{"ok": true}')
        self.assertTrue(used_backup)
        self.assertEqual(self.once.call_args_list[0].args[1], "gemini-3.6-flash")
        self.assertEqual(self.once.call_args_list[1].args[1], "gemini-3.5-flash-lite")

    def test_falls_back_when_primary_quota_is_exhausted(self):
        quota = GeminiAPIError(429, {"error": {"message": "RESOURCE_EXHAUSTED"}})
        self.once.side_effect = [quota, '{"ok": true}']
        text, used_backup = self._call()
        self.assertEqual(text, '{"ok": true}')
        self.assertTrue(used_backup)
        self.assertEqual(self.once.call_count, 2)

    def test_does_not_fall_back_on_unrelated_errors(self):
        other = GeminiAPIError(400, {"error": {"message": "bad request"}})
        self.once.side_effect = other
        with self.assertRaises(GeminiAPIError):
            self._call()
        self.assertEqual(self.once.call_count, 1)
        self.assertEqual(self.once.call_args.args[1], "gemini-3.6-flash")

    def test_primary_success_does_not_use_backup(self):
        self.once.return_value = '{"ok": true}'
        text, used_backup = self._call()
        self.assertEqual(text, '{"ok": true}')
        self.assertFalse(used_backup)
        self.assertEqual(self.once.call_count, 1)
