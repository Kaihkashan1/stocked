from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator

Meal = Literal["breakfast", "lunch", "dinner", "snack", "dessert", "drink", "other"]

# Suggested chips in the apps. Gemini still picks only from this list;
# people can add their own tags when creating or editing a recipe.
RECIPE_TAGS = ["mom's recipes", "veg", "non-veg", "dessert", "high protein", "airfryer"]
_RECIPE_TAGS_LOWER = {tag.lower(): tag for tag in RECIPE_TAGS}
_MAX_TAG_LEN = 32
_MAX_TAGS = 24


def _clean_tags(tags: list[str] | None) -> list[str]:
    """Gemini / ingest: keep only the suggested vocabulary so extraction
    cannot invent a new tag on every save."""
    if not tags:
        return []
    seen: set[str] = set()
    cleaned: list[str] = []
    for tag in tags:
        canonical = _RECIPE_TAGS_LOWER.get(str(tag).strip().lower())
        if canonical and canonical not in seen:
            seen.add(canonical)
            cleaned.append(canonical)
    return cleaned


def _clean_user_tags(tags: list[str] | None) -> list[str]:
    """Add / edit from the apps: suggested tags plus free-text names.
    Commas are stripped because the sheet stores tags as a CSV cell."""
    if not tags:
        return []
    seen: set[str] = set()
    cleaned: list[str] = []
    for tag in tags:
        text = re.sub(r"\s+", " ", str(tag or "").replace(",", " ").strip())
        if not text:
            continue
        if len(text) > _MAX_TAG_LEN:
            text = text[:_MAX_TAG_LEN].rstrip()
        canonical = _RECIPE_TAGS_LOWER.get(text.lower()) or text.lower()
        if not canonical or canonical in seen:
            continue
        seen.add(canonical)
        cleaned.append(canonical)
        if len(cleaned) >= _MAX_TAGS:
            break
    return cleaned


class Ingredient(BaseModel):
    item: str
    quantity: str = ""
    unit: str = ""


class Recipe(BaseModel):
    title: str
    servings: str | None = None
    ingredients: list[Ingredient] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)
    confidence: Literal["high", "medium", "low"] = "medium"
    cuisine: str = "Uncategorized"
    meal: Meal = "other"
    time: str | None = None
    tags: list[str] = Field(default_factory=list)

    _clean_tags_validator = field_validator("tags")(lambda cls, v: _clean_tags(v))


class RecipeCreate(BaseModel):
    """A recipe typed in by hand from the app — skips capture/Gemini
    entirely, so every field is supplied by the user up front. Course is a
    direct field here (the user picks it in the Add-recipe form) rather than
    derived from a `meal` classification the way an ingested recipe's is —
    see app.store.save_recipe / _meal_to_course."""

    title: str
    ingredients: list[str] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)
    course: str = "Main course"
    tags: list[str] = Field(default_factory=list)
    notes: str = ""

    _clean_tags_validator = field_validator("tags")(lambda cls, v: _clean_user_tags(v))


class RecipeUpdate(BaseModel):
    """Partial edit from the app. Unset fields are left alone in the sheet."""

    title: str | None = None
    ingredients: list[str] | None = None
    steps: list[str] | None = None
    favorite: bool | None = None
    notes: str | None = None
    tags: list[str] | None = None
    course: str | None = None

    _clean_tags_validator = field_validator("tags")(lambda cls, v: _clean_user_tags(v) if v is not None else v)


class PantryUpdate(BaseModel):
    items: list[str] = Field(default_factory=list)


# Inventory on the Cupboard tab — distinct from PantryUpdate/`have`, which is
# still the list-screen "What I have" fit filter (a flat string list).
PANTRY_CATEGORIES = (
    "Produce",
    "Dairy & eggs",
    "Meat & seafood",
    "Grains & cupboard",
    "Condiments & spices",
    "Other",
)
PantryUnit = Literal["pcs", "g", "kg"]
PantryStatus = Literal["open", "unopened"]


class PantryItem(BaseModel):
    id: str
    name: str
    category: str = "Other"
    amount: float = 1
    unit: PantryUnit = "pcs"
    status: PantryStatus = "unopened"
    expiry: str | None = None  # YYYY-MM-DD, optional
    notes: str = ""


class PantryInventoryUpdate(BaseModel):
    items: list[PantryItem] = Field(default_factory=list)


class ToBuyItem(BaseModel):
    id: str
    text: str
    qty: str = ""
    checked: bool = False


class ToBuyUpdate(BaseModel):
    items: list[ToBuyItem] = Field(default_factory=list)


class RecipeCategory(BaseModel):
    cuisine: str = "Uncategorized"
    meal: Meal = "other"
    time: str | None = None
    tags: list[str] = Field(default_factory=list)

    _clean_tags_validator = field_validator("tags")(lambda cls, v: _clean_tags(v))


class FetchedPost(BaseModel):
    url: str
    caption: str = ""
    video_path: str | None = None
    thumbnail_path: str | None = None
    thumbnail_url: str | None = None
    media_id: str = ""
