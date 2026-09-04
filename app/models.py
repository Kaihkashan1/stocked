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
_RECIPE_CUES = re.compile(
    r"\b(ingredients?|recipes?|cookbook|tbsp|tsp|teaspoons?|tablespoons?|"
    r"preheat|marinate|sauté|saute|simmer|whisk|mince[ds]?|how to make|"
    r"air[\s-]?fry)\b|"
    r"\d[\d.,/]*\s*(g|kg|ml|l|oz|lb|lbs|cups?|tbsp|tsp)\b",
    re.IGNORECASE,
)
_INGREDIENT_STOP = {
    "the", "and", "for", "with", "from", "fresh", "dried", "optional",
    "salt", "pepper", "oil", "water", "to", "of", "a", "an", "or",
}


def _meaningful_recipe_text(value: str) -> bool:
    text = re.sub(r"\s+", " ", (value or "").strip())
    if len(text) < 2:
        return False
    return _PLACEHOLDER_TEXT.match(text) is None


def source_has_recipe_cues(source_text: str) -> bool:
    """True when the caption/article itself looks like cooking instructions."""
    return bool(_RECIPE_CUES.search(source_text or ""))


def _ingredient_overlap_count(recipe: Recipe, source_text: str) -> int:
    haystack = (source_text or "").lower()
    if not haystack:
        return 0
    hits = 0
    for ing in recipe.ingredients:
        tokens = [
            word
            for word in re.findall(r"[a-z0-9]+", (ing.item or "").lower())
            if len(word) > 2 and word not in _INGREDIENT_STOP
        ]
        if tokens and all(token in haystack for token in tokens):
            hits += 1
    return hits


def recipe_is_grounded(recipe: Recipe, source_text: str) -> bool:
    """Reject dishes Gemini invented that are not supported by the caption."""
    if source_has_recipe_cues(source_text):
        return True
    return _ingredient_overlap_count(recipe, source_text) >= 2


def recipe_is_importable(recipe: Recipe, source_text: str = "", *, require_grounding: bool = False) -> bool:
    """True only when the model returned a cookable recipe, not a
    placeholder or a hallucinated dish from a non-recipe video."""
    if not recipe.is_recipe:
        return False
    if not _meaningful_recipe_text(recipe.title):
        return False
    has_ingredients = any(_meaningful_recipe_text(ing.item) for ing in recipe.ingredients)
    has_steps = any(_meaningful_recipe_text(step) for step in recipe.steps)
    if not (has_ingredients and has_steps):
        return False
    if require_grounding and not recipe_is_grounded(recipe, source_text):
        return False
    return True


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
