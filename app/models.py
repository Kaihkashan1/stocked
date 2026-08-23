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
