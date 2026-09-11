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
from app.match import (
    AISLE_CATEGORIES,
    UNITS,
    _split_leading_quantity,
    canonical_ingredient,
    pantry_category,
    pantry_items,
    split_ingredient_section,
)
from app.errors import NOT_A_RECIPE_MESSAGE, REQUEST_TIMEOUT_MESSAGE
from app.models import (
    FetchedPost,
    Recipe,
    recipe_is_importable,
)

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
_COURSES_CASEFOLDED = {course.casefold(): course for course in COURSES}


def _col_letter(one_based_index: int) -> str:
    """`HEADERS` is small (well under 26 columns), so a single letter is
    always enough — no need for gspread's full A1-notation machinery."""
    return chr(ord("A") + one_based_index - 1)


INGREDIENTS_COL = HEADERS.index("Ingredients") + 1
INGREDIENTS_COL_LETTER = _col_letter(INGREDIENTS_COL)
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


_AISLE_BY_LOWER = {name.casefold(): name for name in AISLE_CATEGORIES}


def _aisle_category(raw) -> str | None:
    text = " ".join(str(raw or "").split())
    if not text:
        return None
    return _AISLE_BY_LOWER.get(text.casefold())


def _category_for_item(name: str, raw_category) -> str:
    """Honor a client aisle that is already in AISLE_CATEGORIES; otherwise
    classify from the ingredient name.

    Stored pantry_inventory / to-buy rows that still carry the previous
    cupboard taxonomy (Baking Supplies, Plant-Based Proteins, custom
    names, …) are not in AISLE_CATEGORIES, so the next read or save
    re-buckets them with pantry_category(). That move is one-way: the old
    label is discarded, not aliased.
    """
    override = _aisle_category(raw_category)
    if override:
        return override
    return pantry_category(canonical_ingredient(name))


def _normalize_pantry_item(raw: dict) -> dict | None:
    name = str(raw.get("name") or "").strip()
    if not name:
        return None
    item_id = str(raw.get("id") or "").strip() or str(uuid.uuid4())
    category = _category_for_item(name, raw.get("category"))
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


def get_pantry_categories(items: list[dict] | None = None) -> list[str]:
    return list(AISLE_CATEGORIES)


def save_pantry_inventory(items: list, categories: list[str] | None = None) -> dict:
    # Client-supplied category lists are ignored; aisles come from
    # AISLE_CATEGORIES. `categories` stays on the signature for the PUT body.
    _ = categories
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
    names = get_pantry_categories(cleaned)
    _write_app_state(pantry_inventory=cleaned, pantry_categories=names)
    return {"items": cleaned, "categories": names}


_UNICODE_FRACTIONS = {
    "¼": 0.25,
    "½": 0.5,
    "¾": 0.75,
    "⅓": 1 / 3,
    "⅔": 2 / 3,
    "⅛": 0.125,
    "⅜": 0.375,
}


def _canonical_to_buy_key(text: str) -> str:
    name = canonical_ingredient(text)
    if name:
        return name
    return " ".join(str(text or "").split()).casefold()


def _same_to_buy_row(item: dict, text: str) -> bool:
    return _canonical_to_buy_key(item.get("text") or "") == _canonical_to_buy_key(text)


def _parse_qty_number(token: str) -> float | None:
    raw = (token or "").strip().replace(",", ".")
    if raw in _UNICODE_FRACTIONS:
        return _UNICODE_FRACTIONS[raw]
    if "/" in raw and raw.count("/") == 1:
        left, right = raw.split("/")
        try:
            denom = float(right)
        except ValueError:
            return None
        if denom == 0:
            return None
        try:
            return float(left) / denom
        except ValueError:
            return None
    try:
        return float(raw)
    except ValueError:
        return None


def _canonical_unit(unit: str) -> str:
    text = " ".join((unit or "").strip(".,;").lower().split())
    if text in {"floz", "fl.oz", "fl oz", "fluid oz", "fluid ounce", "fluid ounces"}:
        return "fl oz"
    if text.endswith("es") and text[:-2] in UNITS:
        return text[:-2]
    if text.endswith("s") and text[:-1] in UNITS:
        return text[:-1]
    return text


def _format_qty_amount(amount: float, unit: str) -> str:
    if abs(amount - round(amount)) < 1e-9:
        number = str(int(round(amount)))
    else:
        number = f"{amount:.3f}".rstrip("0").rstrip(".")
    return f"{number} {unit}".strip()


def _parse_source_qty(qty: str) -> tuple[float, str] | None:
    text = (qty or "").strip()
    if not text:
        return None
    leading, _rest = _split_leading_quantity(text)
    if not leading:
        return None
    words = leading.split()
    amount = _parse_qty_number(words[0])
    if amount is None:
        return None
    unit = _canonical_unit(" ".join(words[1:]))
    return amount, unit


def _merge_qty(sources: list[dict]) -> str:
    """Sum same-unit source qtys; mixed or unparseable parts join with ' + '."""
    grouped: dict[str, float] = {}
    order: list[str] = []
    leftovers: list[str] = []
    for source in sources:
        raw = str(source.get("qty") or "").strip()
        if not raw:
            continue
        parsed = _parse_source_qty(raw)
        if parsed is None:
            leftovers.append(raw)
            continue
        amount, unit = parsed
        if unit not in grouped:
            order.append(unit)
            grouped[unit] = 0.0
        grouped[unit] += amount
    parts = [_format_qty_amount(grouped[unit], unit) for unit in order]
    parts.extend(leftovers)
    return " + ".join(parts)


def _normalize_source(raw) -> dict | None:
    if hasattr(raw, "model_dump"):
        raw = raw.model_dump()
    if not isinstance(raw, dict):
        return None
    recipe_id = raw.get("recipe_id")
    if recipe_id is not None and recipe_id != "":
        try:
            recipe_id = int(recipe_id)
        except (TypeError, ValueError):
            return None
    else:
        recipe_id = None
    return {
        "recipe_id": recipe_id,
        "qty": str(raw.get("qty") or "").strip(),
    }


def _normalize_to_buy_sources(raw: dict) -> list[dict]:
    incoming = raw.get("sources")
    if isinstance(incoming, list) and incoming:
        sources: list[dict] = []
        seen: set = set()
        for entry in incoming:
            source = _normalize_source(entry)
            if source is None:
                continue
            key = source["recipe_id"]
            if key in seen:
                sources = [item for item in sources if item["recipe_id"] != key]
            else:
                seen.add(key)
            sources.append(source)
        return sources
    qty = str(raw.get("qty") or "").strip()
    return [{"recipe_id": None, "qty": qty}]


def _finalize_to_buy_item(item: dict) -> dict:
    sources = item.get("sources") or []
    item["qty"] = _merge_qty(sources)
    item["category"] = _category_for_item(item["text"], item.get("category"))
    return item


def _normalize_to_buy_item(raw: dict) -> dict | None:
    text = str(raw.get("text") or "").strip()
    if not text:
        return None
    sources = _normalize_to_buy_sources(raw)
    if not sources:
        return None
    item_id = str(raw.get("id") or "").strip() or str(uuid.uuid4())
    return _finalize_to_buy_item({
        "id": item_id,
        "text": text,
        "category": raw.get("category"),
        "notes": str(raw.get("notes") or "").strip()[:200],
        "checked": bool(raw.get("checked", False)),
        "sources": sources,
    })


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


def add_to_buy_source(text: str, qty: str = "", recipe_id: int | None = None) -> list[dict]:
    trimmed = str(text or "").strip()
    if not trimmed:
        return get_to_buy_items()
    qty = str(qty or "").strip()
    if recipe_id is not None:
        recipe_id = int(recipe_id)
    items = get_to_buy_items()
    target = next((item for item in items if _same_to_buy_row(item, trimmed)), None)
    source = {"recipe_id": recipe_id, "qty": qty}
    if target is None:
        items.append({
            "id": str(uuid.uuid4()),
            "text": trimmed,
            "category": _category_for_item(trimmed, None),
            "notes": "",
            "checked": False,
            "sources": [source],
        })
    else:
        target["sources"] = [
            entry for entry in target.get("sources") or []
            if entry.get("recipe_id") != recipe_id
        ]
        target["sources"].append(source)
        target["checked"] = False
    return save_to_buy_items(items)


def remove_to_buy_source(text: str, recipe_id: int | None = None) -> list[dict]:
    trimmed = str(text or "").strip()
    if not trimmed:
        return get_to_buy_items()
    if recipe_id is not None:
        recipe_id = int(recipe_id)
    items = get_to_buy_items()
    next_items: list[dict] = []
    for item in items:
        if not _same_to_buy_row(item, trimmed):
            next_items.append(item)
            continue
        sources = [
            entry for entry in item.get("sources") or []
            if entry.get("recipe_id") != recipe_id
        ]
        if not sources:
            continue
        item = dict(item)
        item["sources"] = sources
        next_items.append(item)
    return save_to_buy_items(next_items)


# Gemini's free-tier quota resets on its own clock (~midnight Pacific, per
# GEMINI_QUOTA_MESSAGE), not the server's UTC day — so the counter has to key
# off Pacific dates or it would reset hours early/late and the Settings card
# would disagree with the actual quota error.
_PACIFIC = ZoneInfo("America/Los_Angeles")


def record_gemini_read() -> None:
    """Ticks Settings "Imports today" once per Gemini API call we actually
    make — success or failure, primary or backup model. Failed photo/
    Instagram reads still count when Google accepted the request. There is
    no quota-remaining endpoint; this is a local tally of those calls."""
    today = datetime.now(_PACIFIC).date().isoformat()
    usage = _read_app_state().get("gemini_usage") or {}
    count = usage.get("count", 0) + 1 if usage.get("date") == today else 1
    _write_app_state(gemini_usage={"date": today, "count": count})


def get_gemini_reads_today() -> int:
    usage = _read_app_state().get("gemini_usage") or {}
    today = datetime.now(_PACIFIC).date().isoformat()
    return usage.get("count", 0) if usage.get("date") == today else 0


IMPORT_LOG_TITLE = "ImportLog"
IMPORT_LOG_HEADERS = ["timestamp", "url", "status", "reason", "used_backup", "model"]
_BERLIN = ZoneInfo("Europe/Berlin")
_LOG_YMD = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(\s.*)$")
_LOG_DMY_HM = re.compile(r"^(\d{2})-(\d{2})-(\d{4})[ T](\d{2}):(\d{2})")
_CONFIDENCE_SUFFIX = re.compile(r"\s*\((high|medium|low)\)\s*$", re.I)
# Vercel Hobby ingest can run up to 300s. A "started" row older than that
# means the function died before it could write saved/error (Shortcut
# timeout, 499, platform kill) — surface it as a timeout instead of
# leaving a permanent "Saving…" line.
_STALE_STARTED_SECONDS = 300


def _import_model_name(used_backup: bool, stored: str = "") -> str:
    if stored.strip():
        return stored.strip()
    if used_backup:
        return (settings.gemini_fallback_model or "").strip() or "gemini-3.5-flash-lite"
    return (settings.gemini_model or "").strip() or "gemini-3.6-flash"


def _widen_import_log(worksheet, cols: int = len(IMPORT_LOG_HEADERS)) -> None:
    """ImportLog was created with 5 columns; writing F1 without this 400s."""
    if worksheet.col_count < cols:
        worksheet.resize(rows=max(worksheet.row_count, 2), cols=cols)


@lru_cache(maxsize=1)
def _import_log_worksheet():
    spreadsheet = _worksheet().spreadsheet
    try:
        worksheet = spreadsheet.worksheet(IMPORT_LOG_TITLE)
    except gspread.WorksheetNotFound:
        worksheet = spreadsheet.add_worksheet(title=IMPORT_LOG_TITLE, rows=2, cols=len(IMPORT_LOG_HEADERS))
        worksheet.append_row(IMPORT_LOG_HEADERS, value_input_option="RAW")
        return worksheet
    existing = worksheet.row_values(1)
    if existing[: len(IMPORT_LOG_HEADERS)] == IMPORT_LOG_HEADERS:
        return worksheet
    if not any(existing):
        _widen_import_log(worksheet)
        worksheet.append_row(IMPORT_LOG_HEADERS, value_input_option="RAW")
        return worksheet
    if existing[:5] == IMPORT_LOG_HEADERS[:5] and (len(existing) < 6 or existing[5] != "model"):
        try:
            _widen_import_log(worksheet)
            worksheet.update_cell(1, 6, "model")
        except Exception:
            logger.exception("Could not add ImportLog model column")
        return worksheet
    logger.warning("ImportLog header row does not match %s", IMPORT_LOG_HEADERS)
    return worksheet


def _display_log_timestamp(raw: str) -> str:
    """Sheet used to write YYYY-MM-DD; show DD-MM-YYYY, keep the time suffix."""
    text = (raw or "").strip()
    match = _LOG_YMD.match(text)
    if match:
        return f"{match.group(3)}-{match.group(2)}-{match.group(1)}{match.group(4)}"
    return text


def _log_headline(reason: str) -> str:
    return _CONFIDENCE_SUFFIX.sub("", (reason or "").strip())


def _log_row_time(timestamp: str) -> datetime | None:
    match = _LOG_DMY_HM.match((timestamp or "").strip())
    if not match:
        return None
    try:
        return datetime(
            int(match.group(3)),
            int(match.group(2)),
            int(match.group(1)),
            int(match.group(4)),
            int(match.group(5)),
            tzinfo=_BERLIN,
        )
    except ValueError:
        return None


def _present_import_rows(rows: list[dict], now: datetime | None = None) -> list[dict]:
    """Newest-first. Drop 'started' once that URL has a later outcome;
    treat a started row older than the Vercel ingest ceiling as a timeout."""
    clock = now or datetime.now(_BERLIN)
    done_urls: set[str] = set()
    presented: list[dict] = []
    for row in rows:
        status = (row.get("status") or "").strip()
        url = (row.get("url") or "").strip()
        if status == "started":
            if url in done_urls:
                continue
            started_at = _log_row_time(str(row.get("timestamp") or ""))
            age = (clock - started_at).total_seconds() if started_at else None
            if age is None or age >= _STALE_STARTED_SECONDS:
                presented.append({**row, "status": "error", "reason": REQUEST_TIMEOUT_MESSAGE})
            else:
                presented.append({**row, "reason": row.get("reason") or "Saving…"})
            continue
        if status in {"saved", "duplicate", "error"} and url:
            done_urls.add(url)
        presented.append(row)
    return presented


def log_import(url: str | None, status: str, reason: str, used_backup: bool = False) -> None:
    """Append one ImportLog row. Best-effort — must never break an import."""
    try:
        timestamp = datetime.now(_BERLIN).strftime("%d-%m-%Y %H:%M %Z")
        model = _import_model_name(used_backup)
        row = [
            timestamp,
            (url or "").strip() or "(photo)",
            status,
            _log_headline(reason or "")[:500],
            "TRUE" if used_backup else "FALSE",
            model,
        ]
        sheet = _import_log_worksheet()
        _widen_import_log(sheet)
        sheet.append_row(row, value_input_option="RAW")
    except Exception:
        logger.exception("Failed to write import log")


def _header_index(headers: list[str], name: str) -> int | None:
    want = name.strip().lower()
    for index, header in enumerate(headers):
        if str(header).strip().lower() == want:
            return index
    return None


def _cell(row: list, index: int | None) -> str:
    if index is None or index < 0 or index >= len(row):
        return ""
    return str(row[index] or "").strip()


def _parse_import_log_values(values: list[list], limit: int = 50) -> list[dict]:
    """Build API rows from a raw sheet dump.

    gspread's get_all_records() raises when the header row has duplicate
    empty cells (common after adding a column). Reading values by column
    name keeps older ImportLog tabs readable.
    """
    if not values:
        return []
    headers = [str(cell or "") for cell in values[0]]
    ts_i = _header_index(headers, "timestamp")
    url_i = _header_index(headers, "url")
    status_i = _header_index(headers, "status")
    reason_i = _header_index(headers, "reason")
    backup_i = _header_index(headers, "used_backup")
    model_i = _header_index(headers, "model")
    if ts_i is None and url_i is None:
        ts_i, url_i, status_i, reason_i, backup_i = 0, 1, 2, 3, 4
        if model_i is None and len(headers) > 5:
            model_i = 5
    rows = []
    for raw in values[1:]:
        if not any(str(cell or "").strip() for cell in raw):
            continue
        used_backup = _cell(raw, backup_i).lower() in TRUE_VALUES
        stored_model = _cell(raw, model_i)
        rows.append(
            {
                "timestamp": _display_log_timestamp(_cell(raw, ts_i)),
                "url": _cell(raw, url_i),
                "status": _cell(raw, status_i),
                "reason": _log_headline(_cell(raw, reason_i)),
                "used_backup": used_backup,
                "model": _import_model_name(used_backup, stored_model),
            }
        )
    rows.reverse()
    rows = _present_import_rows(rows)
    return rows[: max(0, limit)]


def get_recent_imports(limit: int = 50) -> list[dict]:
    try:
        values = _import_log_worksheet().get_all_values()
    except Exception:
        logger.exception("Failed to read import log")
        return []
    return _parse_import_log_values(values, limit=limit)


def source_exists(url: str) -> bool:
    url = normalize_url(url)
    values = _worksheet().col_values(SOURCE_COL)
    known = {normalize_url(item) for item in values[1:] if item}
    return url in known


def save_recipe(recipe: Recipe, post: FetchedPost) -> None:
    if not recipe_is_importable(recipe):
        raise RuntimeError(NOT_A_RECIPE_MESSAGE)
    ingredients = format_ingredient_lines(recipe.ingredients)
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


def replace_ingredient_lines(row_id: int, lines: list[str]) -> None:
    """Rewrite only the Ingredients cell — used when backfilling section
    headings onto recipes that were saved as a flat list."""
    text = "\n".join(f"- {line}" for line in lines)
    _worksheet().update(
        f"{INGREDIENTS_COL_LETTER}{row_id}",
        [[text]],
        value_input_option="RAW",
    )


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
    """Case-fold against the known Course vocabulary, else fall back to
    Main course — the same shape as app/models.py's _RECIPE_TAGS_LOWER tag
    lookup, via a precomputed dict rather than a linear scan. Mirrored (not
    shared — no code-sharing path across Python/Swift for this) by
    ios/RecipeBox/Models.swift's Course.resolve()."""
    return _COURSES_CASEFOLDED.get((value or "").strip().casefold(), "Main course")


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


def format_ingredient_lines(items) -> str:
    """Sheet cell text: optional heading lines (`- Sauce:`) then items."""
    return "\n".join(_iter_formatted_ingredient_lines(items))


def ingredient_strings(items) -> list[str]:
    """API/app shape: the same lines as the sheet, without leading bullets."""
    return _parse_lines(format_ingredient_lines(items), bullets=True)


def _iter_formatted_ingredient_lines(items):
    last = ""
    for item in items:
        section = (getattr(item, "section", None) or "").strip()
        name = (item.item or "").strip()
        parsed_section, parsed_item = split_ingredient_section(name)
        if parsed_item is None and parsed_section:
            if parsed_section.casefold() != last.casefold():
                yield f"- ## {parsed_section}"
                last = parsed_section
            continue
        if not section and parsed_section:
            section = parsed_section
            name = parsed_item or name
        elif (
            section
            and parsed_section
            and parsed_section.casefold() == section.casefold()
            and parsed_item
        ):
            name = parsed_item
        if section and section.casefold() != last.casefold():
            yield f"- ## {section}"
            last = section
        if not name:
            continue
        qty = " ".join(part for part in (item.quantity, item.unit) if part).strip()
        if qty:
            yield f"- {qty} {name}"
        else:
            yield f"- {name}"
