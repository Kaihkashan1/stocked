import json
from datetime import datetime
from unittest import TestCase
from unittest.mock import patch
from zoneinfo import ZoneInfo

from google.genai.errors import APIError as GeminiAPIError

from app.errors import NOT_A_RECIPE_MESSAGE, REQUEST_TIMEOUT_MESSAGE
from app.extract import _generate_with_retry, _parse_recipe_set
from app.store import _parse_import_log_values, _present_import_rows


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


def _pasta(**overrides):
    recipe = {
        "title": "Pasta",
        "ingredients": [{"item": "spaghetti", "quantity": "200g"}],
        "steps": ["Boil water."],
        "confidence": "high",
        "is_recipe": True,
    }
    recipe.update(overrides)
    return recipe


class ParseRecipeSetTests(TestCase):
    def test_empty_placeholder_is_not_a_recipe(self):
        payload = json.dumps(
            {
                "content_kind": "not_recipe",
                "recipes": [
                    {
                        "title": "not a recipe",
                        "ingredients": [],
                        "steps": [],
                        "confidence": "low",
                        "is_recipe": False,
                    }
                ]
            }
        )
        with self.assertRaises(RuntimeError) as ctx:
            _parse_recipe_set(payload)
        self.assertEqual(str(ctx.exception), NOT_A_RECIPE_MESSAGE)

    def test_empty_recipe_list_is_not_a_recipe(self):
        with self.assertRaises(RuntimeError) as ctx:
            _parse_recipe_set(json.dumps({"content_kind": "not_recipe", "recipes": []}))
        self.assertEqual(str(ctx.exception), NOT_A_RECIPE_MESSAGE)

    def test_rejects_invented_recipe_from_a_vlog(self):
        payload = json.dumps(
            {
                "content_kind": "not_recipe",
                "recipes": [
                    _pasta(
                        title="Meeting the Mayor",
                        is_recipe=True,
                    )
                ],
            }
        )
        with self.assertRaises(RuntimeError) as ctx:
            _parse_recipe_set(payload)
        self.assertEqual(str(ctx.exception), NOT_A_RECIPE_MESSAGE)

    def test_rejects_when_model_marks_object_as_not_a_recipe(self):
        payload = json.dumps({"content_kind": "recipe", "recipes": [_pasta(is_recipe=False)]})
        with self.assertRaises(RuntimeError) as ctx:
            _parse_recipe_set(payload)
        self.assertEqual(str(ctx.exception), NOT_A_RECIPE_MESSAGE)

    def test_rejects_title_only_or_steps_only(self):
        with self.assertRaises(RuntimeError):
            _parse_recipe_set(
                json.dumps(
                    {
                        "content_kind": "recipe",
                        "recipes": [_pasta(ingredients=[{"item": "spaghetti"}], steps=[])],
                    }
                )
            )
        with self.assertRaises(RuntimeError):
            _parse_recipe_set(
                json.dumps(
                    {
                        "content_kind": "recipe",
                        "recipes": [_pasta(ingredients=[], steps=["Boil water."])],
                    }
                )
            )

    def test_drops_placeholder_when_a_real_recipe_is_also_present(self):
        payload = json.dumps(
            {
                "content_kind": "recipe",
                "recipes": [
                    {
                        "title": "not a recipe",
                        "ingredients": [],
                        "steps": [],
                        "confidence": "low",
                        "is_recipe": False,
                    },
                    _pasta(),
                ],
            }
        )
        recipes = _parse_recipe_set(payload)
        self.assertEqual([item.title for item in recipes], ["Pasta"])

    def test_keeps_recipes_with_ingredients_and_steps(self):
        payload = json.dumps({"content_kind": "recipe", "recipes": [_pasta()]})
        recipes = _parse_recipe_set(payload)
        self.assertEqual(len(recipes), 1)
        self.assertEqual(recipes[0].title, "Pasta")

    def test_keeps_recipe_when_caption_has_no_ingredients(self):
        payload = json.dumps({"content_kind": "recipe", "recipes": [_pasta()]})
        recipes = _parse_recipe_set(payload)
        self.assertEqual(recipes[0].title, "Pasta")


class ImportLogParseTests(TestCase):
    def test_reads_rows_when_header_has_duplicate_empty_cells(self):
        values = [
            ["timestamp", "url", "status", "reason", "used_backup", "model", "", ""],
            ["04-09-2026 17:00 CEST", "https://instagram.com/p/abc", "ok", "Pasta", "FALSE", "gemini-3.6-flash", "", ""],
            ["04-09-2026 16:00 CEST", "(photo)", "error", "That didn't look like a recipe.", "TRUE", "gemini-3.5-flash-lite", "", ""],
        ]
        rows = _parse_import_log_values(values, limit=50)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["reason"], "That didn't look like a recipe.")
        self.assertTrue(rows[0]["used_backup"])
        self.assertEqual(rows[1]["url"], "https://instagram.com/p/abc")
        self.assertFalse(rows[1]["used_backup"])


class ImportLogPresentTests(TestCase):
    def test_stale_started_becomes_timeout(self):
        now = datetime(2026, 9, 4, 18, 0, tzinfo=ZoneInfo("Europe/Berlin"))
        rows = [
            {
                "timestamp": "04-09-2026 17:00 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "started",
                "reason": "Saving…",
                "used_backup": False,
                "model": "gemini-3.6-flash",
            }
        ]
        presented = _present_import_rows(rows, now=now)
        self.assertEqual(presented[0]["status"], "error")
        self.assertEqual(presented[0]["reason"], REQUEST_TIMEOUT_MESSAGE)

    def test_recent_started_stays_in_progress(self):
        now = datetime(2026, 9, 4, 17, 2, tzinfo=ZoneInfo("Europe/Berlin"))
        rows = [
            {
                "timestamp": "04-09-2026 17:00 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "started",
                "reason": "Saving…",
                "used_backup": False,
                "model": "gemini-3.6-flash",
            }
        ]
        presented = _present_import_rows(rows, now=now)
        self.assertEqual(presented[0]["status"], "started")
        self.assertEqual(presented[0]["reason"], "Saving…")

    def test_hides_started_when_a_later_outcome_exists(self):
        rows = [
            {
                "timestamp": "04-09-2026 17:10 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "saved",
                "reason": "Pasta",
                "used_backup": False,
                "model": "x",
            },
            {
                "timestamp": "04-09-2026 17:00 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "started",
                "reason": "Saving…",
                "used_backup": False,
                "model": "x",
            },
        ]
        presented = _present_import_rows(rows)
        self.assertEqual([row["status"] for row in presented], ["saved"])

    def test_keeps_timeout_even_if_the_save_later_succeeds(self):
        rows = [
            {
                "timestamp": "04-09-2026 17:10 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "saved",
                "reason": "Pasta",
                "used_backup": False,
                "model": "x",
            },
            {
                "timestamp": "04-09-2026 17:05 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "error",
                "reason": REQUEST_TIMEOUT_MESSAGE,
                "used_backup": False,
                "model": "x",
            },
            {
                "timestamp": "04-09-2026 17:00 CEST",
                "url": "https://instagram.com/p/abc",
                "status": "started",
                "reason": "Saving…",
                "used_backup": False,
                "model": "x",
            },
        ]
        presented = _present_import_rows(rows)
        self.assertEqual([row["status"] for row in presented], ["saved", "error"])
        self.assertEqual(presented[1]["reason"], REQUEST_TIMEOUT_MESSAGE)

    def test_keeps_separate_photo_imports(self):
        rows = [
            {
                "timestamp": "04-09-2026 17:10 CEST",
                "url": "(photo)",
                "status": "saved",
                "reason": "Pancakes",
                "used_backup": False,
                "model": "x",
            },
            {
                "timestamp": "04-09-2026 17:00 CEST",
                "url": "(photo)",
                "status": "saved",
                "reason": "Curry",
                "used_backup": False,
                "model": "x",
            },
        ]
        presented = _present_import_rows(rows)
        self.assertEqual([row["reason"] for row in presented], ["Pancakes", "Curry"])


class PantryCategoryTests(TestCase):
    def test_honors_explicit_aisle_override(self):
        from app.store import _normalize_pantry_item

        rice = _normalize_pantry_item({"name": "Rice", "category": "Vegetables"})
        self.assertEqual(rice["category"], "Vegetables")

    def test_classifies_when_category_missing(self):
        from app.store import _normalize_pantry_item, _normalize_to_buy_item

        rice = _normalize_pantry_item({"name": "Rice"})
        self.assertEqual(rice["category"], "Grains & pasta")
        soy = _normalize_to_buy_item({"text": "Soy sauce"})
        self.assertEqual(soy["category"], "Sauces & condiments")

    def test_rebuckets_old_taxonomy_one_way(self):
        from app.store import _normalize_pantry_item

        oats = _normalize_pantry_item({"name": "Oats", "category": "Baking Supplies"})
        self.assertEqual(oats["category"], "Grains & pasta")
        lemon = _normalize_pantry_item({"name": "Lemon", "category": "Produce"})
        self.assertEqual(lemon["category"], "Fruit")
        tofu = _normalize_pantry_item({"name": "Tofu", "category": "Plant-Based Proteins"})
        self.assertEqual(tofu["category"], "Legumes")

    def test_pantry_categories_follow_aisle_order(self):
        from app.match import AISLE_CATEGORIES
        from app.store import get_pantry_categories

        self.assertEqual(get_pantry_categories([]), list(AISLE_CATEGORIES))
        self.assertEqual(AISLE_CATEGORIES[-1], "Other")


class ToBuySourceTests(TestCase):
    def test_merge_qty_sums_same_unit(self):
        from app.store import _merge_qty

        self.assertEqual(
            _merge_qty([{"qty": "200 g"}, {"qty": "100 g"}]),
            "300 g",
        )
        self.assertEqual(
            _merge_qty([{"qty": "1 cup"}, {"qty": "2 cups"}]),
            "3 cup",
        )

    def test_merge_qty_joins_mixed_units(self):
        from app.store import _merge_qty

        self.assertEqual(
            _merge_qty([{"qty": "2"}, {"qty": "1 cup"}]),
            "2 + 1 cup",
        )
        self.assertEqual(
            _merge_qty([{"qty": "a handful"}, {"qty": "1 tbsp"}]),
            "1 tbsp + a handful",
        )

    def test_legacy_qty_becomes_manual_source(self):
        from app.store import _normalize_to_buy_item

        item = _normalize_to_buy_item({"text": "Onion", "qty": "2"})
        self.assertEqual(item["sources"], [{"recipe_id": None, "qty": "2"}])
        self.assertEqual(item["qty"], "2")
        self.assertEqual(item["category"], "Vegetables")

    def test_qty_is_derived_not_trusted(self):
        from app.store import _normalize_to_buy_item

        item = _normalize_to_buy_item({
            "text": "onion",
            "qty": "999",
            "sources": [
                {"recipe_id": 2, "qty": "1"},
                {"recipe_id": 5, "qty": "1"},
            ],
        })
        self.assertEqual(item["qty"], "2")
        self.assertEqual(len(item["sources"]), 2)
