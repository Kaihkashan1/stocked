from __future__ import annotations

import json
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
    "Notes",
]
SOURCE_COL = 5  # 1-based, matches HEADERS
CUISINE_COL = 10
MEAL_COL = 11
TIME_COL = 12
TAGS_COL = 13
FAVORITE_COL = 14
NOTES_COL = 15
LAST_COL_LETTER = "O"  # matches len(HEADERS)
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
    if existing[:14] == HEADERS[:14]:
        worksheet.update(f"A1:{LAST_COL_LETTER}1", [HEADERS], value_input_option="RAW")
        return
    if existing[:13] == HEADERS[:13]:
        worksheet.update(f"A1:{LAST_COL_LETTER}1", [HEADERS], value_input_option="RAW")
        return
    if existing[:9] == HEADERS[:9]:
        worksheet.update(f"A1:{LAST_COL_LETTER}1", [HEADERS], value_input_option="RAW")
        return
    logger.warning("Sheet already has a header row that does not match %s", HEADERS)


STATE_SHEET_TITLE = "AppState"


@lru_cache(maxsize=1)
def _state_worksheet():
    spreadsheet = _worksheet().spreadsheet
    try:
        return spreadsheet.worksheet(STATE_SHEET_TITLE)
    except gspread.WorksheetNotFound:
        worksheet = spreadsheet.add_worksheet(title=STATE_SHEET_TITLE, rows=2, cols=1)
        worksheet.update("A1", [["{}"]], value_input_option="RAW")
        return worksheet


def get_plan_ids() -> list[int]:
    """The meal plan is shared across devices (iOS + web) — this is the
    only piece of client state worth syncing; "what I have" is more of a
    per-session browsing context than something to carry between devices."""
    raw = _state_worksheet().acell("A1").value or "{}"
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = {}
    ids = data.get("plan_ids") or []
    return sorted({int(i) for i in ids if str(i).lstrip("-").isdigit()})


def save_plan_ids(ids: list[int]) -> list[int]:
    clean = sorted({int(i) for i in ids})
    _state_worksheet().update("A1", [[json.dumps({"plan_ids": clean})]], value_input_option="RAW")
    return clean


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
        "",  # Thumbnail: intentionally not saved — the app shows a letter
        # avatar instead. post.thumbnail_path (a local file, not this URL)
        # is still passed to Gemini for visual extraction; only the saved,
        # user-facing image is skipped.
        saved_at,
        _clean_cuisine(recipe.cuisine),
        recipe.meal,
        recipe.time or "",
        ", ".join(_clean_tag(tag) for tag in recipe.tags if _clean_tag(tag)),
        "",  # Favorite: not set on save, toggled later from the app
        "",  # Notes: added later from the app
    ]
    # A plain append_row() lets the Sheets API auto-detect "the table" to
    # append after — which, in practice, sometimes appended a new row
    # shifted many columns to the right instead of at column A (confirmed
    # live: this corrupted several real rows and briefly took down
    # /api/recipes entirely). Writing to an explicit, computed row number
    # is unambiguous and can't drift like that. col_values(1) returns every
    # row up to the last non-blank title, including blank/soft-deleted rows
    # in between, so its length is exactly the last real row number.
    worksheet = _worksheet()
    next_row = len(worksheet.col_values(1)) + 1
    worksheet.update(f"A{next_row}:{LAST_COL_LETTER}{next_row}", [row], value_input_option="USER_ENTERED")
    logger.info("Saved %r to Google Sheets", recipe.title)


def create_recipe(
    *,
    title: str,
    servings: str | None,
    ingredients: list[str],
    steps: list[str],
    cuisine: str,
    meal: str,
    time: str | None,
    tags: list[str],
    notes: str,
) -> dict | None:
    """Adds a recipe typed straight into the app — no capture pipeline, no
    Gemini call, no source URL. Ingredients/steps are formatted the same
    way update_recipe re-serializes them, so a later edit round-trips
    cleanly."""
    ingredients_text = "\n".join(f"- {line}" for line in ingredients)
    steps_text = "\n".join(f"{i}. {line}" for i, line in enumerate(steps, start=1))
    saved_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    clean_cuisine = _clean_cuisine(cuisine)
    clean_meal = _clean_meal(meal)
    clean_tags = [_clean_tag(tag) for tag in tags if _clean_tag(tag)]
    row = [
        title,
        servings or "",
        ingredients_text,
        steps_text,
        "",  # Source: typed in by hand, no URL
        "",  # Caption
        "high",  # Confidence: user-authored, not a model guess
        "",  # Thumbnail
        saved_at,
        clean_cuisine,
        clean_meal,
        time or "",
        ", ".join(clean_tags),
        "",  # Favorite
        notes,
    ]
    # See save_recipe for why this writes to an explicit row instead of
    # using append_row's auto-detected table range.
    worksheet = _worksheet()
    row_id = len(worksheet.col_values(1)) + 1
    worksheet.update(f"A{row_id}:{LAST_COL_LETTER}{row_id}", [row], value_input_option="USER_ENTERED")
    logger.info("Created row %s (%r) via manual entry", row_id, title)

    # Build the response from what we just wrote instead of a second read —
    # same reasoning as update_recipe: one Sheets API round trip, not two.
    return {
        "id": row_id,
        "title": title,
        "servings": servings or None,
        "ingredients": ingredients,
        "pantry": pantry_items(ingredients),
        "steps": steps,
        "source": "",
        "caption": "",
        "confidence": "high",
        "thumbnail": "",
        "saved_at": saved_at,
        "cuisine": clean_cuisine,
        "meal": clean_meal,
        "time": time or None,
        "tags": clean_tags,
        "favorite": False,
        "notes": notes,
        "ingredients_text": ingredients_text,
        "steps_text": steps_text,
    }


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
    favorite, notes, cuisine, meal, time, tags). Untouched fields keep their
    current sheet value."""
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
    notes = fields.get("notes", current["notes"]) or ""
    cuisine = _clean_cuisine(fields.get("cuisine", current["cuisine"]))
    meal = _clean_meal(fields.get("meal", current["meal"]))
    time = fields.get("time", current["time"]) or ""
    tags_in = fields.get("tags")
    tags = [_clean_tag(tag) for tag in tags_in if _clean_tag(tag)] if tags_in is not None else current["tags"]

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
        cuisine,
        meal,
        time,
        ", ".join(tags),
        "TRUE" if favorite else "",
        notes,
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
        "notes": notes,
        "cuisine": cuisine,
        "meal": meal,
        "time": time or None,
        "tags": tags,
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
        "notes": str(record.get("Notes") or "").strip(),
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
