from __future__ import annotations

import unittest

from app.match import canonical_ingredient, collapse_catalog, pantry_items


class CanonicalIngredientTests(unittest.TestCase):
    def test_strips_units_and_prep_words(self):
        self.assertEqual(canonical_ingredient("2 cups finely chopped spinach"), "spinach")

    def test_singularizes(self):
        self.assertEqual(canonical_ingredient("3 tomatoes"), "tomato")

    def test_strips_meat_forms(self):
        self.assertEqual(canonical_ingredient("2 chicken breasts"), "chicken")
        self.assertEqual(canonical_ingredient("500g chicken thigh"), "chicken")

    def test_protected_phrase_keeps_protein(self):
        self.assertEqual(canonical_ingredient("1 tbsp protein powder"), "protein powder")

    def test_strips_vague_measure_and_quantity_words(self):
        # "spoon" isn't a real unit word like tbsp/tsp, but it shouldn't
        # end up glued onto the ingredient name either.
        self.assertEqual(canonical_ingredient("1 spoon turmeric"), "turmeric")
        self.assertEqual(canonical_ingredient("few sprig coriander"), "coriander")
        self.assertEqual(canonical_ingredient("half mushroom"), "mushroom")
        self.assertEqual(canonical_ingredient("med red onion"), "red onion")

    def test_plural_unit_is_caught_without_a_second_entry(self):
        self.assertEqual(canonical_ingredient("2 packets fajita seasoning"), "fajita seasoning")
        self.assertEqual(canonical_ingredient("3 spoons salt"), "salt")

    def test_collapses_prawn_descriptors(self):
        for text in ["deveined prawn", "freshwater prawn", "frozen king prawn", "marinated prawn", "prawn"]:
            self.assertEqual(canonical_ingredient(text), "prawn")


class CollapseCatalogTests(unittest.TestCase):
    def test_folds_descriptive_variant_into_existing_entry(self):
        # canonical_ingredient("spinach leaves") actually produces "spinach
        # leave" (see _CATALOG_DESCRIPTORS comment) — this is the real
        # shape of a catalog entry, not raw ingredient text.
        self.assertEqual(
            collapse_catalog(["spinach", "spinach leave"]),
            ["spinach"],
        )

    def test_leaves_entry_alone_without_base_item(self):
        # "curry leaves" has no bare "curry" entry in the catalog, so it's
        # a real ingredient name, not a descriptive variant to fold away.
        self.assertEqual(
            collapse_catalog(["curry leave", "rice"]),
            ["curry leave", "rice"],
        )

    def test_unrelated_items_are_untouched(self):
        items = ["chicken", "garlic", "onion"]
        self.assertEqual(collapse_catalog(items), sorted(items))


class PantryItemsTests(unittest.TestCase):
    def test_spinach_leaves_collapse_end_to_end(self):
        ingredients_a = ["1 cup chopped spinach"]
        ingredients_b = ["2 cups spinach leaves"]
        catalog = set(pantry_items(ingredients_a)) | set(pantry_items(ingredients_b))
        self.assertEqual(collapse_catalog(sorted(catalog)), ["spinach"])


if __name__ == "__main__":
    unittest.main()
