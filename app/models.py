from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator

Meal = Literal["breakfast", "lunch", "dinner", "snack", "dessert", "drink", "other"]

# Suggested chips in the apps. Gemini still picks only from this list;
# people can add their own tags when creating or editing a recipe.
RECIPE_TAGS = ["mom's recipes", "veg", "non-veg", "my recipes", "high protein", "airfryer"]
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
    Commas are stripped because the sheet stores tags as a CSV cell.

    This server-side function is the canonical spec for what a "clean" user
    tag is. It's mirrored — not shared, there's no code-sharing path across
    Python/JS/Swift for this — by app/static/app.js's normalizeUserTag() and
    ios/RecipeBox/Models.swift's normalizeRecipeTag(). All three must agree
    on: strip commas → collapse whitespace → clip to _MAX_TAG_LEN chars →
    case-fold against the known vocabulary, else lowercase; and the caller
    enforces the _MAX_TAGS cap and case-insensitive dedup. If you change any
    of that here, change it in both mirrors too."""
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
    # Component of a multi-part meal (Sauce, Chicken, Rice). Empty for a
    # single list. Stored in the sheet as a heading line, then the items.
    section: str = ""


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
    is_recipe: bool

    _clean_tags_validator = field_validator("tags")(lambda cls, v: _clean_tags(v))


_PLACEHOLDER_TEXT = re.compile(
    r"^(not a recipe|n/?a|none|nothing|unknown|untitled|no ingredients?|no steps?|no recipe)\b",
    re.IGNORECASE,
)


def _meaningful_recipe_text(value: str) -> bool:
    text = re.sub(r"\s+", " ", (value or "").strip())
    if len(text) < 2:
        return False
    return _PLACEHOLDER_TEXT.match(text) is None


def recipe_is_importable(recipe: Recipe) -> bool:
    """True when the model returned a cookable dish, not an empty placeholder."""
    if not recipe.is_recipe:
        return False
    if not _meaningful_recipe_text(recipe.title):
        return False
    has_ingredients = any(_meaningful_recipe_text(ing.item) for ing in recipe.ingredients)
    has_steps = any(_meaningful_recipe_text(step) for step in recipe.steps)
    return has_ingredients and has_steps


class RecipeSet(BaseModel):
    """One Gemini call can return several recipes from an Instagram
    carousel (distinct dishes) or a single recipe whose steps span slides."""

    content_kind: Literal["recipe", "not_recipe"]
    recipes: list[Recipe] = Field(default_factory=list, max_length=5)


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
# Aisle names live in app.match.AISLE_CATEGORIES (shared with to-buy).
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
    categories: list[str] | None = None


class ToBuySource(BaseModel):
    recipe_id: int | None = None
    qty: str = ""


class ToBuyItem(BaseModel):
    id: str
    text: str
    category: str = "Other"
    qty: str = ""
    notes: str = ""
    checked: bool = False
    sources: list[ToBuySource] = Field(default_factory=list)


class ToBuyUpdate(BaseModel):
    items: list[ToBuyItem] = Field(default_factory=list)


class ToBuySourceChange(BaseModel):
    text: str
    qty: str = ""
    recipe_id: int | None = None


class RecipeCategory(BaseModel):
    cuisine: str = "Uncategorized"
    meal: Meal = "other"
    time: str | None = None
    tags: list[str] = Field(default_factory=list)

    _clean_tags_validator = field_validator("tags")(lambda cls, v: _clean_tags(v))


class FetchedSlide(BaseModel):
    """One Instagram carousel item after download — a short clip or a still."""

    kind: Literal["video", "image"]
    path: str


class FetchedPost(BaseModel):
    url: str
    caption: str = ""
    video_path: str | None = None
    thumbnail_path: str | None = None
    thumbnail_url: str | None = None
    image_paths: list[str] = Field(default_factory=list)
    slides: list[FetchedSlide] = Field(default_factory=list)
    media_id: str = ""
