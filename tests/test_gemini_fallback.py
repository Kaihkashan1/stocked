import json
from unittest import TestCase
from unittest.mock import patch

from google.genai.errors import APIError as GeminiAPIError

from app.errors import NOT_A_RECIPE_MESSAGE
from app.extract import _generate_with_retry, _parse_recipe_set


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

    def test_rejects_hallucinated_recipe_when_caption_is_not_cooking(self):
        payload = json.dumps({"content_kind": "recipe", "recipes": [_pasta(title="Meeting the Mayor")]})
        with self.assertRaises(RuntimeError) as ctx:
            _parse_recipe_set(
                payload,
                source_text="Had a great time meeting the mayor downtown today with the team.",
                require_grounding=True,
            )
        self.assertEqual(str(ctx.exception), NOT_A_RECIPE_MESSAGE)

    def test_keeps_recipe_when_two_ingredients_appear_in_caption(self):
        payload = json.dumps(
            {
                "content_kind": "recipe",
                "recipes": [
                    _pasta(ingredients=[{"item": "spaghetti"}, {"item": "garlic"}])
                ],
            }
        )
        recipes = _parse_recipe_set(
            payload,
            source_text="Making spaghetti with garlic tonight.",
            require_grounding=True,
        )
        self.assertEqual(recipes[0].title, "Pasta")
