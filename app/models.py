from typing import Literal

from pydantic import BaseModel, Field

Meal = Literal["breakfast", "lunch", "dinner", "snack", "dessert", "drink", "other"]


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


class RecipeCreate(BaseModel):
    """A recipe typed in by hand from the app — skips capture/Gemini
    entirely, so every field is supplied by the user up front."""

    title: str
    servings: str | None = None
    ingredients: list[str] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)
    cuisine: str = "Uncategorized"
    meal: Meal = "other"
    time: str | None = None
    tags: list[str] = Field(default_factory=list)
    notes: str = ""


class RecipeUpdate(BaseModel):
    """Partial edit from the app. Unset fields are left alone in the sheet."""

    title: str | None = None
    servings: str | None = None
    ingredients: list[str] | None = None
    steps: list[str] | None = None
    favorite: bool | None = None
    notes: str | None = None


class PlanUpdate(BaseModel):
    ids: list[int] = Field(default_factory=list)


class RecipeCategory(BaseModel):
    cuisine: str = "Uncategorized"
    meal: Meal = "other"
    time: str | None = None
    tags: list[str] = Field(default_factory=list)


class FetchedPost(BaseModel):
    url: str
    caption: str = ""
    video_path: str | None = None
    thumbnail_path: str | None = None
    thumbnail_url: str | None = None
    media_id: str = ""
