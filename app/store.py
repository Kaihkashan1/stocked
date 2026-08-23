from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from functools import lru_cache

import gspread

from app.config import settings
from app.fetch import normalize_url
from app.match import pantry_items
from app.models import FetchedPost, Recipe

logger = logging.getLogger(__name__)

HEADERS = [
    "Title",
    "Servings",
    "Ingredients",
    "Steps",
    "Source",
    "Caption",
    "Confidence",
    "Thumbnail",
    "Saved at",
    "Cuisine",
    "Meal",
    "Time",
    "Tags",
    "Favorite",
]
SOURCE_COL = 5  # 1-based, matches HEADERS
CUISINE_COL = 10
MEAL_COL = 11
TIME_COL = 12
TAGS_COL = 13
FAVORITE_COL = 14
LAST_COL_LETTER = "N"  # matches len(HEADERS)
TRUE_VALUES = {"true", "yes", "1", "y"}


@lru_cache(maxsize=1)
def _worksheet():
    if not settings.google_sheet_id:
        raise RuntimeError("GOOGLE_SHEET_ID is missing. Add it to .env or Vercel env vars.")

    info = settings.service_account_info()
    client = gspread.service_account_from_dict(info)
    try:
        sheet = client.open_by_key(settings.google_sheet_id)
    except PermissionError as exc:
        email = info.get("client_email") or "the service account"
        raise RuntimeError(
            f"The Sheet is not shared with {email}. "
            "Open the spreadsheet → Share → paste that email → Editor → "
            "uncheck Notify people → Share."
        ) from exc
    worksheet = sheet.sheet1
    _ensure_headers(worksheet)
    return worksheet


def _ensure_headers(worksheet) -> None:
    existing = worksheet.row_values(1)
    if existing[: len(HEADERS)] == HEADERS:
        return
    if not any(existing):
        worksheet.append_row(HEADERS, value_input_option="RAW")
        return
    if existing[:13] == HEADERS[:13]:
        worksheet.update(f"A1:{LAST_COL_LETTER}1", [HEADERS], value_input_option="RAW")
        return
    if existing[:9] == HEADERS[:9]:
        worksheet.update(f"A1:{LAST_COL_LETTER}1", [HEADERS], value_input_option="RAW")
        return
    logger.warning("Sheet already has a header row that does not match %s", HEADERS)


def source_exists(url: str) -> bool:
    url = normalize_url(url)
    values = _worksheet().col_values(SOURCE_COL)
    known = {normalize_url(item) for item in values[1:] if item}
    return url in known


def save_recipe(recipe: Recipe, post: FetchedPost) -> None:
    ingredients = "\n".join(_format_ingredient(item) for item in recipe.ingredients)
    steps = "\n".join(f"{i}. {step}" for i, step in enumerate(recipe.steps, start=1))
    saved_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    row = [
        recipe.title,
        recipe.servings or "",
        ingredients,
        steps,
        post.url,
        post.caption,
        recipe.confidence,
        post.thumbnail_url or "",
        saved_at,
        _clean_cuisine(recipe.cuisine),
        recipe.meal,
        recipe.time or "",
        ", ".join(_clean_tag(tag) for tag in recipe.tags if _clean_tag(tag)),
        "",  # Favorite: not set on save, toggled later from the app
    ]
    _worksheet().append_row(row, value_input_option="USER_ENTERED")
    logger.info("Saved %r to Google Sheets", recipe.title)


def delete_recipe(row_id: int) -> bool:
    """Blanks the row instead of removing it. Recipe ids are literal sheet
    row numbers throughout this app (client caches, favorites, the meal
    plan) — an actual row delete would shift every later row's id and
    silently break all of that until the next full refresh. list_recipes()
    and get_recipe() already skip blank-title rows, so a blanked row is
    simply invisible."""
    if get_recipe(row_id) is None:
        return False
    blank_row = [""] * len(HEADERS)
    _worksheet().update(f"A{row_id}:{LAST_COL_LETTER}{row_id}", [blank_row], value_input_option="RAW")
    logger.info("Cleared row %s", row_id)
    return True


def update_recipe(row_id: int, **fields) -> dict | None:
    """Partial update of a saved recipe (title, servings, ingredients, steps,
    favorite). Untouched fields keep their current sheet value."""
    current = get_recipe(row_id)
    if current is None:
        return None

    title = fields.get("title", current["title"])
    servings = fields.get("servings", current["servings"]) or ""
    ingredients = fields.get("ingredients")
    ingredients_text = (
        "\n".join(f"- {line}" for line in ingredients) if ingredients is not None else current["ingredients_text"]
    )
    steps = fields.get("steps")
    steps_text = (
        "\n".join(f"{i}. {line}" for i, line in enumerate(steps, start=1)) if steps is not None else current["steps_text"]
    )
    favorite = fields.get("favorite", current["favorite"])

    row = [
        title,
        servings,
        ingredients_text,
        steps_text,
        current["source"],
        current["caption"],
        current["confidence"],
        current["thumbnail"],
        current["saved_at"],
        current["cuisine"],
        current["meal"],
        current["time"] or "",
        ", ".join(current["tags"]),
        "TRUE" if favorite else "",
    ]
    _worksheet().update(f"A{row_id}:{LAST_COL_LETTER}{row_id}", [row], value_input_option="USER_ENTERED")
    logger.info("Updated row %s (%r)", row_id, title)

    # Build the response from what we just wrote instead of a second read —
    # one Sheets API round trip per edit instead of two.
    ingredients_list = ingredients if ingredients is not None else current["ingredients"]
    steps_list = steps if steps is not None else current["steps"]
    return {
        **current,
        "title": title,
        "servings": servings or None,
        "ingredients": ingredients_list,
        "pantry": pantry_items(ingredients_list),
        "steps": steps_list,
        "favorite": favorite,
        "ingredients_text": ingredients_text,
        "steps_text": steps_text,
    }


def list_recipes() -> list[dict]:
    records = _worksheet().get_all_records()
    recipes = []
    for index, record in enumerate(records, start=2):
        if not str(record.get("Title") or "").strip():
            continue
        recipes.append(_record_to_recipe(index, record))
    recipes.sort(key=lambda item: item["saved_at"], reverse=True)
    return recipes


def get_recipe(row_id: int) -> dict | None:
    if row_id < 2:
        return None
    records = _worksheet().get_all_records()
    index = row_id - 2
    if index < 0 or index >= len(records):
        return None
    record = records[index]
    if not str(record.get("Title") or "").strip():
        return None
    return _record_to_recipe(row_id, record)


def _record_to_recipe(row_id: int, record: dict) -> dict:
    ingredients_text = str(record.get("Ingredients") or "")
    steps_text = str(record.get("Steps") or "")
    ingredients = _parse_lines(ingredients_text, bullets=True)
    steps = _parse_lines(steps_text, numbered=True)
    tags_raw = str(record.get("Tags") or "")
    return {
        "id": row_id,
        "title": str(record.get("Title") or "").strip(),
        "servings": str(record.get("Servings") or "").strip() or None,
        "ingredients": ingredients,
        "pantry": pantry_items(ingredients),
        "steps": steps,
        "source": str(record.get("Source") or "").strip(),
        "caption": str(record.get("Caption") or "").strip(),
        "confidence": str(record.get("Confidence") or "medium").strip() or "medium",
        "thumbnail": str(record.get("Thumbnail") or "").strip(),
        "saved_at": str(record.get("Saved at") or "").strip(),
        "cuisine": _clean_cuisine(str(record.get("Cuisine") or "")),
        "meal": _clean_meal(str(record.get("Meal") or "")),
        "time": str(record.get("Time") or "").strip() or None,
        "tags": [_clean_tag(tag) for tag in tags_raw.split(",") if _clean_tag(tag)],
        "favorite": str(record.get("Favorite") or "").strip().lower() in TRUE_VALUES,
        "ingredients_text": ingredients_text,
        "steps_text": steps_text,
    }


def _parse_lines(text: str, bullets: bool = False, numbered: bool = False) -> list[str]:
    lines = []
    for raw in (text or "").splitlines():
        line = raw.strip()
        if bullets:
            line = re.sub(r"^[-*•]\s*", "", line)
        if numbered:
            line = re.sub(r"^\d+[.)]\s*", "", line)
        if line:
            lines.append(line)
    return lines


def _clean_cuisine(value: str) -> str:
    cuisine = (value or "").strip()
    return cuisine or "Uncategorized"


def _clean_meal(value: str) -> str:
    meal = (value or "").strip().lower()
    allowed = {"breakfast", "lunch", "dinner", "snack", "dessert", "drink", "other"}
    return meal if meal in allowed else "other"


def _clean_tag(value: str) -> str:
    return re.sub(r"\s+", "-", (value or "").strip().lower()).strip("-")


def _format_ingredient(item) -> str:
    qty = " ".join(part for part in (item.quantity, item.unit) if part).strip()
    if qty:
        return f"- {qty} {item.item}"
    return f"- {item.item}"
