from __future__ import annotations

import json
import logging
import re
import uuid
from datetime import datetime, timezone
from functools import lru_cache
from zoneinfo import ZoneInfo

import gspread

from app.config import settings
from app.fetch import normalize_url
from app.match import pantry_items
from app.models import PANTRY_CATEGORIES, FetchedPost, Recipe

logger = logging.getLogger(__name__)

# Servings, Caption, Thumbnail, Cuisine, Meal and Time used to live here too.
# Removed from the sheet by hand (they'd genuinely gone unused in the app —
# see Course below for the one exception this created). "Course" is new:
# appended at the end rather than interleaved, so upgrading an older sheet
# (see _ensure_headers) is a pure column addition, never a reshuffle of
# columns that already hold real data.
HEADERS = [
    "Title",
    "Ingredients",
    "Steps",
    "Source",
    "Confidence",
    "Saved at",
    "Tags",
    "Favorite",
    "Notes",
    "Course",
]
TRUE_VALUES = {"true", "yes", "1", "y"}
COURSES = ("Main course", "Appetizers", "Desserts", "Dips")


def _col_letter(one_based_index: int) -> str:
    """`HEADERS` is small (well under 26 columns), so a single letter is
    always enough — no need for gspread's full A1-notation machinery."""
    return chr(ord("A") + one_based_index - 1)


SOURCE_COL = HEADERS.index("Source") + 1  # 1-based, matches HEADERS
LAST_COL_LETTER = _col_letter(len(HEADERS))
COURSE_COL_LETTER = _col_letter(HEADERS.index("Course") + 1)


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
    existing_headers = _ensure_headers(worksheet)
    _ensure_course_validation(worksheet, existing_headers)
    return worksheet


def _ensure_headers(worksheet) -> list[str]:
    """Returns the sheet's current header row, creating/extending it first
    if needed. Callers that only care about a specific column (see
    _ensure_course_validation) can reuse this instead of issuing their own
    row_values(1) read."""
    existing = worksheet.row_values(1)
    if existing[: len(HEADERS)] == HEADERS:
        return existing
    if not any(existing):
        worksheet.append_row(HEADERS, value_input_option="RAW")
        return list(HEADERS)
    if existing == HEADERS[:-1]:
        # Exactly the pre-Course shape: every other header already matches,
        # in the same order, nothing missing in between — so this is a pure
        # append (one new cell) rather than a rewrite of a row that already
        # has real columns under it.
        worksheet.update_cell(1, len(HEADERS), HEADERS[-1])
        return list(HEADERS)
    logger.warning("Sheet already has a header row that does not match %s", HEADERS)
    return existing


def _ensure_course_validation(worksheet, headers: list[str]) -> None:
    """Keeps the Course column dropdown in sync with COURSES.

    A sheet that predates Dips often still has a strict three-value list
    (Main course / Appetizers / Desserts). USER_ENTERED writes of "Dips"
    then fail or land blank, and the next read maps the empty cell back to
    Main course — which looks like "saving as a dip does nothing".

    Takes the header row from _ensure_headers rather than re-reading it —
    this only runs once per warm process (behind _worksheet's lru_cache),
    but on Vercel that's once per cold start, so it's worth not doubling
    the read."""
    course_index = HEADERS.index("Course")
    if len(headers) <= course_index or headers[course_index] != "Course":
        return
    try:
        from gspread.utils import ValidationConditionType

        worksheet.add_validation(
            f"{COURSE_COL_LETTER}2:{COURSE_COL_LETTER}",
            ValidationConditionType.one_of_list,
            list(COURSES),
            showCustomUi=True,
            strict=False,
        )
    except Exception:
        logger.warning("Could not refresh the Course column dropdown", exc_info=True)


def _update_recipe_row(worksheet, row_id: int, row: list) -> None:
    """Writes one recipe row. USER_ENTERED is the usual path; a RAW retry
    covers a leftover strict Course dropdown that still rejects Dips.

    Only retried when the API actually rejects the request (code 400,
    e.g. a data-validation failure) — a rate limit, auth problem, or other
    APIError is a real failure and should propagate rather than be masked
    by a silent retry in a different (less type-aware) input mode."""
    range_name = f"A{row_id}:{LAST_COL_LETTER}{row_id}"
    try:
        worksheet.update(range_name, [row], value_input_option="USER_ENTERED")
    except gspread.exceptions.APIError as exc:
        if exc.code != 400:
            raise
        logger.warning("USER_ENTERED write rejected for row %s (code %s); retrying RAW", row_id, exc.code)
        worksheet.update(range_name, [row], value_input_option="RAW")


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


def _read_app_state() -> dict:
    raw = _state_worksheet().acell("A1").value or "{}"
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _write_app_state(**updates) -> None:
    data = _read_app_state()
    data.update(updates)
    _state_worksheet().update("A1", [[json.dumps(data)]], value_input_option="RAW")


def get_have_items() -> list[str]:
    """List-screen "What I have" — a flat string list used for fit %. Synced
    across devices. Distinct from pantry inventory (see get_pantry_inventory)."""
    items = _read_app_state().get("have") or []
    return sorted({str(item).strip().lower() for item in items if str(item).strip()})


def save_have_items(items: list[str]) -> list[str]:
    clean = sorted({str(item).strip().lower() for item in items if str(item).strip()})
    _write_app_state(have=clean)
    return clean


def _normalize_expiry(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    # Accept full ISO timestamps from clients; store date-only.
    return text[:10]


def _normalize_pantry_item(raw: dict) -> dict | None:
    name = str(raw.get("name") or "").strip()
    if not name:
        return None
    item_id = str(raw.get("id") or "").strip() or str(uuid.uuid4())
    category = str(raw.get("category") or "Other").strip()
    if category == "Grains & pantry":
        category = "Grains & cupboard"
    if category not in PANTRY_CATEGORIES:
        category = "Other"
    unit = str(raw.get("unit") or "pcs").strip().lower()
    if unit not in ("pcs", "g", "kg"):
        unit = "pcs"
    status = str(raw.get("status") or "unopened").strip().lower()
    if status not in ("open", "unopened"):
        status = "unopened"
    try:
        amount = float(raw.get("amount", 1))
    except (TypeError, ValueError):
        amount = 1.0
    if amount <= 0:
        amount = 1.0
    notes = str(raw.get("notes") or "").strip()
    return {
        "id": item_id,
        "name": name,
        "category": category,
        "amount": amount,
        "unit": unit,
        "status": status,
        "expiry": _normalize_expiry(raw.get("expiry")),
        "notes": notes,
    }


def get_pantry_inventory() -> list[dict]:
    raw_items = _read_app_state().get("pantry_inventory") or []
    cleaned: list[dict] = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        item = _normalize_pantry_item(raw)
        if item:
            cleaned.append(item)
    return cleaned


def save_pantry_inventory(items: list) -> list[dict]:
    cleaned: list[dict] = []
    seen_ids: set[str] = set()
    for raw in items:
        if hasattr(raw, "model_dump"):
            raw = raw.model_dump()
        if not isinstance(raw, dict):
            continue
        item = _normalize_pantry_item(raw)
        if not item or item["id"] in seen_ids:
            continue
        seen_ids.add(item["id"])
        cleaned.append(item)
    _write_app_state(pantry_inventory=cleaned)
    return cleaned


def _normalize_to_buy_item(raw: dict) -> dict | None:
    text = str(raw.get("text") or "").strip()
    if not text:
        return None
    item_id = str(raw.get("id") or "").strip() or str(uuid.uuid4())
    return {
        "id": item_id,
        "text": text,
        "qty": str(raw.get("qty") or "").strip(),
        "checked": bool(raw.get("checked", False)),
    }


def get_to_buy_items() -> list[dict]:
    raw_items = _read_app_state().get("to_buy") or []
    cleaned: list[dict] = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        item = _normalize_to_buy_item(raw)
        if item:
            cleaned.append(item)
    return cleaned


def save_to_buy_items(items: list) -> list[dict]:
    cleaned: list[dict] = []
    seen_ids: set[str] = set()
    for raw in items:
        if hasattr(raw, "model_dump"):
            raw = raw.model_dump()
        if not isinstance(raw, dict):
            continue
        item = _normalize_to_buy_item(raw)
        if not item or item["id"] in seen_ids:
            continue
        seen_ids.add(item["id"])
        cleaned.append(item)
    _write_app_state(to_buy=cleaned)
    return cleaned


# Gemini's free-tier quota resets on its own clock (~midnight Pacific, per
# GEMINI_QUOTA_MESSAGE), not the server's UTC day — so the counter has to key
# off Pacific dates or it would reset hours early/late and the Settings card
# would disagree with the actual quota error.
_PACIFIC = ZoneInfo("America/Los_Angeles")


def record_gemini_read() -> None:
    """Ticks the daily Gemini call counter, kept in AppState alongside the
    pantry. There's no Gemini-side endpoint that reports free-tier quota
    usage, so this is the only way the Settings "API usage" card can show a
    real number instead of a guess."""
    today = datetime.now(_PACIFIC).date().isoformat()
    usage = _read_app_state().get("gemini_usage") or {}
    count = usage.get("count", 0) + 1 if usage.get("date") == today else 1
    _write_app_state(gemini_usage={"date": today, "count": count})


def get_gemini_reads_today() -> int:
    usage = _read_app_state().get("gemini_usage") or {}
    today = datetime.now(_PACIFIC).date().isoformat()
    return usage.get("count", 0) if usage.get("date") == today else 0


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
        ingredients,
        steps,
        post.url,
        recipe.confidence,
        saved_at,
        ", ".join(_clean_tag(tag) for tag in recipe.tags if _clean_tag(tag)),
        "",  # Favorite: not set on save, toggled later from the app
        "",  # Notes: added later from the app
        _meal_to_course(recipe.meal),
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
    _update_recipe_row(worksheet, next_row, row)
    logger.info("Saved %r to Google Sheets", recipe.title)


def create_recipe(
    *,
    title: str,
    ingredients: list[str],
    steps: list[str],
    course: str,
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
    clean_tags = [_clean_tag(tag) for tag in tags if _clean_tag(tag)]
    clean_course = _clean_course(course)
    row = [
        title,
        ingredients_text,
        steps_text,
        "",  # Source: typed in by hand, no URL
        "high",  # Confidence: user-authored, not a model guess
        saved_at,
        ", ".join(clean_tags),
        "",  # Favorite
        notes,
        clean_course,
    ]
    # See save_recipe for why this writes to an explicit row instead of
    # using append_row's auto-detected table range.
    worksheet = _worksheet()
    row_id = len(worksheet.col_values(1)) + 1
    _update_recipe_row(worksheet, row_id, row)
    logger.info("Created row %s (%r) via manual entry", row_id, title)

    # Build the response from what we just wrote instead of a second read —
    # same reasoning as update_recipe: one Sheets API round trip, not two.
    return {
        "id": row_id,
        "title": title,
        "ingredients": ingredients,
        "pantry": pantry_items(ingredients),
        "steps": steps,
        "source": "",
        "confidence": "high",
        "saved_at": saved_at,
        "course": clean_course,
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
    """Partial update of a saved recipe (title, ingredients, steps, favorite,
    notes, tags, course). Untouched fields keep their current sheet value."""
    current = get_recipe(row_id)
    if current is None:
        return None

    title = fields.get("title", current["title"])
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
    tags_in = fields.get("tags")
    tags = [_clean_tag(tag) for tag in tags_in if _clean_tag(tag)] if tags_in is not None else current["tags"]
    course = _clean_course(fields["course"]) if fields.get("course") is not None else current["course"]

    row = [
        title,
        ingredients_text,
        steps_text,
        current["source"],
        current["confidence"],
        current["saved_at"],
        ", ".join(tags),
        "TRUE" if favorite else "",
        notes,
        course,
    ]
    _update_recipe_row(_worksheet(), row_id, row)
    logger.info("Updated row %s (%r)", row_id, title)

    # Build the response from what we just wrote instead of a second read —
    # one Sheets API round trip per edit instead of two.
    ingredients_list = ingredients if ingredients is not None else current["ingredients"]
    steps_list = steps if steps is not None else current["steps"]
    return {
        **current,
        "title": title,
        "ingredients": ingredients_list,
        "pantry": pantry_items(ingredients_list),
        "steps": steps_list,
        "favorite": favorite,
        "notes": notes,
        "tags": tags,
        "course": course,
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
        "ingredients": ingredients,
        "pantry": pantry_items(ingredients),
        "steps": steps,
        "source": str(record.get("Source") or "").strip(),
        "confidence": str(record.get("Confidence") or "medium").strip() or "medium",
        "saved_at": str(record.get("Saved at") or "").strip(),
        "course": _clean_course(str(record.get("Course") or "")),
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


def _clean_course(value: str) -> str:
    value = (value or "").strip()
    for course in COURSES:
        if value.casefold() == course.casefold():
            return course
    return "Main course"


def _meal_to_course(meal: str) -> str:
    """Mirrors the app's own Course(meal:) mapping (see Models.swift) —
    used only for recipes captured through /ingest, where there's no user
    in the loop to pick a course directly the way the Add-recipe forms do."""
    if meal == "dessert":
        return "Desserts"
    if meal == "snack":
        return "Appetizers"
    return "Main course"


def _clean_tag(value: str) -> str:
    # Collapses stray whitespace but does *not* convert spaces to hyphens —
    # the fixed tags ("high protein", "mom's recipes") are multi-word on
    # purpose, and mangling them into kebab-case broke exact-match chip
    # highlighting and filtering against those exact strings.
    return re.sub(r"\s+", " ", (value or "").replace(",", " ").strip().lower())


def _format_ingredient(item) -> str:
    qty = " ".join(part for part in (item.quantity, item.unit) if part).strip()
    if qty:
        return f"- {qty} {item.item}"
    return f"- {item.item}"
