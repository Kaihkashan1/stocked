"""Fill cuisine / meal / tags for recipes saved before categorization existed.

Run:  python -m app.backfill
"""

from __future__ import annotations

from app.extract import categorize_recipe
from app.store import recipes_needing_categories, update_categories


def main() -> int:
    pending = recipes_needing_categories()
    if not pending:
        print("Every recipe already has a cuisine.")
        return 0

    print(f"Categorizing {len(pending)} recipe(s)…")
    for recipe in pending:
        category = categorize_recipe(
            title=recipe["title"],
            ingredients=recipe["ingredients_text"],
            steps=recipe["steps_text"],
            caption=recipe["caption"],
            servings=recipe["servings"] or "",
        )
        update_categories(recipe["id"], category)
        tags = ", ".join(category.tags) or "—"
        print(
            f"  {recipe['title']}: {category.cuisine} / {category.meal} / {tags}"
        )
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
