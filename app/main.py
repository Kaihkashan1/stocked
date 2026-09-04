from __future__ import annotations

import json
import logging
import os
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from google.genai.errors import APIError as GeminiAPIError

from app.auth import require_secret
from app.config import ROOT, settings
from app.errors import GEMINI_DAILY_QUOTA, friendly_message, gemini_is_busy
from app.extract import extract_recipe
from app.fetch import get_apify_usage
from app.match import STAPLES, grouped_pantry
from app.models import FetchedPost, PantryInventoryUpdate, PantryUpdate, RecipeCreate, RecipeUpdate, ToBuyUpdate
from app.pipeline import jobs, process_recipe
from app.store import (
    create_recipe,
    delete_recipe,
    get_gemini_reads_today,
    get_have_items,
    get_pantry_inventory,
    get_recent_imports,
    get_recipe,
    get_to_buy_items,
    ingredient_strings,
    list_recipes,
    log_import,
    save_have_items,
    save_pantry_inventory,
    save_to_buy_items,
    update_recipe,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)

STATIC = ROOT / "app" / "static"


@asynccontextmanager
async def lifespan(_app: FastAPI):
    logger.info(
        "Recipe Box ready  model=%s  sheet=%s  apify=%s",
        settings.gemini_model,
        "yes" if settings.google_sheet_id else "MISSING",
        "yes" if settings.apify_api_token.strip() else "MISSING",
    )
    if not settings.gemini_api_key:
        logger.warning("GEMINI_API_KEY is not set")
    if not settings.has_service_account():
        logger.warning("Service account is missing (file or GOOGLE_SERVICE_ACCOUNT_JSON)")
    yield


app = FastAPI(title="Recipe Box", lifespan=lifespan)


@app.get("/")
async def home():
    return FileResponse(STATIC / "index.html")


@app.get("/health")
async def health():
    return {
        "ok": True,
        "gemini_key": bool(settings.gemini_api_key),
        "sheet_id": bool(settings.google_sheet_id),
        "service_account": settings.has_service_account(),
    }


@app.get("/api/recipes")
async def api_list_recipes():
    recipes = [_public(recipe) for recipe in list_recipes()]
    items = {
        item
        for recipe in recipes
        for item in recipe.get("pantry") or []
        if item not in STAPLES
    }
    # Custom pantry items (typed in free-hand, not derived from any recipe)
    # need to show up in the catalog too, so they get a real category
    # instead of vanishing until they happen to match a recipe.
    items |= set(get_have_items())
    return {"recipes": recipes, "pantry": grouped_pantry(sorted(items, key=str.lower))}


@app.get("/api/recipes/{row_id}")
async def api_get_recipe(row_id: int):
    recipe = get_recipe(row_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return _public(recipe)


@app.post("/api/recipes", dependencies=[Depends(require_secret)])
async def api_create_recipe(body: RecipeCreate):
    created = create_recipe(**body.model_dump())
    if not created:
        raise HTTPException(status_code=500, detail="Could not save recipe")
    return _public(created)


MAX_PHOTO_BYTES = 4 * 1024 * 1024  # Vercel's request body limit is ~4.5MB; stay under it.


@app.post("/api/extract-photo", dependencies=[Depends(require_secret)])
async def api_extract_photo(photo: UploadFile = File(...)):
    """Reads a recipe out of a photo (a card, a cookbook page, a screenshot —
    Gemini isn't picky) via the same vision extraction used for a
    video/thumbnail capture. Doesn't save anything — the app pre-fills the
    manual Add Recipe form with the result so the user reviews/edits before
    committing, since a single still photo has no caption text to fall back
    on and is more error-prone than a normal capture."""
    content = await photo.read()
    if len(content) > MAX_PHOTO_BYTES:
        raise HTTPException(status_code=413, detail="That photo is too large. Please use a smaller image.")

    suffix = Path(photo.filename or "").suffix or ".jpg"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(content)
        tmp_path = Path(tmp.name)

    recipes = []
    used_backup = False
    try:
        post = FetchedPost(url="", caption="", video_path=None, thumbnail_path=str(tmp_path))
        try:
            recipes, used_backup = extract_recipe(post)
        except Exception as exc:
            # Not just GeminiAPIError: a slow response now fails as a plain
            # httpx.TimeoutException (see app.extract's explicit call
            # timeout) rather than a Gemini-shaped error, and still needs
            # the same friendly 503/429/502 treatment instead of leaking a
            # raw exception as an unhandled 500.
            used_backup = bool(getattr(exc, "used_backup", False))
            message = friendly_message(exc)
            log_import(None, "error", message, used_backup=used_backup)
            if isinstance(exc, GeminiAPIError) and exc.code == 429:
                status = 429
            elif gemini_is_busy(exc):
                status = 503
            else:
                status = 502
            raise HTTPException(status_code=status, detail=message) from exc
    finally:
        tmp_path.unlink(missing_ok=True)

    if not recipes:
        log_import(None, "error", "Gemini returned no recipes.", used_backup=used_backup)
        raise HTTPException(status_code=502, detail="Gemini returned no recipes.")
    recipe = recipes[0]
    log_import(None, "saved", f"{recipe.title} ({recipe.confidence})", used_backup=used_backup)

    ingredients = ingredient_strings(recipe.ingredients)
    return {
        "title": recipe.title,
        "servings": recipe.servings,
        "ingredients": ingredients,
        "steps": recipe.steps,
        "cuisine": recipe.cuisine,
        "meal": recipe.meal,
        "time": recipe.time,
        "tags": recipe.tags,
        "confidence": recipe.confidence,
    }


@app.patch("/api/recipes/{row_id}", dependencies=[Depends(require_secret)])
async def api_update_recipe(row_id: int, body: RecipeUpdate):
    # update_recipe() does its own get_recipe() existence check internally —
    # checking again here would be a second full-sheet read for nothing.
    updated = update_recipe(row_id, **body.model_dump(exclude_unset=True))
    if not updated:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return _public(updated)


@app.delete("/api/recipes/{row_id}", dependencies=[Depends(require_secret)])
async def api_delete_recipe(row_id: int):
    if not delete_recipe(row_id):
        raise HTTPException(status_code=404, detail="Recipe not found")
    return {"status": "deleted", "id": row_id}


@app.get("/api/pantry")
async def api_get_pantry():
    return {"items": get_have_items()}


@app.put("/api/pantry", dependencies=[Depends(require_secret)])
async def api_put_pantry(body: PantryUpdate):
    return {"items": save_have_items(body.items)}


@app.get("/api/pantry-inventory")
async def api_get_pantry_inventory():
    """Full Pantry-tab inventory (amount, unit, expiry, …). Separate from
    /api/pantry, which remains the flat "What I have" fit-filter list."""
    return {"items": get_pantry_inventory()}


@app.put("/api/pantry-inventory", dependencies=[Depends(require_secret)])
async def api_put_pantry_inventory(body: PantryInventoryUpdate):
    return {"items": save_pantry_inventory(body.items)}


@app.get("/api/to-buy")
async def api_get_to_buy():
    return {"items": get_to_buy_items()}


@app.put("/api/to-buy", dependencies=[Depends(require_secret)])
async def api_put_to_buy(body: ToBuyUpdate):
    return {"items": save_to_buy_items(body.items)}


@app.get("/api/usage", dependencies=[Depends(require_secret)])
async def api_usage():
    """Backs the Settings Import limits card. Gemini has no
    quota-remaining endpoint for a free-tier key, so that count is
    self-tracked (see app.store.record_gemini_read); Apify's is a live
    account query, so it can't drift from what Apify actually bills.
    `apify` is null when the token is missing or the call fails — the app
    should just hide that half of the card rather than fake a number."""
    return {
        "gemini": {"used": get_gemini_reads_today(), "limit": GEMINI_DAILY_QUOTA},
        "apify": get_apify_usage(),
    }


@app.get("/api/import-log", dependencies=[Depends(require_secret)])
async def api_import_log():
    return {"imports": get_recent_imports(limit=50)}


@app.get("/jobs", dependencies=[Depends(require_secret)])
async def list_jobs():
    return {"jobs": list(jobs)}


@app.post("/ingest", dependencies=[Depends(require_secret)])
async def ingest(request: Request, background_tasks: BackgroundTasks):
    content = await _read_content(request)
    if not content.strip():
        return JSONResponse(
            status_code=400,
            content={"status": "error", "detail": "No content in request body"},
        )
    # Serverless freezes after the response, so ingest must finish in-request on Vercel.
    if os.environ.get("VERCEL"):
        # Keep HTTP 200 on save/duplicate/error so the iPhone Shortcut can
        # read `status` and notify only when it is "error".
        return process_recipe(content)
    background_tasks.add_task(process_recipe, content)
    return {"status": "queued", "message": "Saving… I'll add it to your sheet shortly."}


def _public(recipe: dict) -> dict:
    return {key: value for key, value in recipe.items() if not key.endswith("_text")}


async def _read_content(request: Request) -> str:
    raw = await request.body()
    if not raw:
        return ""
    ctype = request.headers.get("content-type", "")
    text = raw.decode("utf-8", errors="replace").strip()
    if "application/json" in ctype or text.startswith("{") or text.startswith("["):
        try:
            return _from_json(json.loads(text))
        except json.JSONDecodeError:
            return text
    return text


def _from_json(body: Any) -> str:
    if isinstance(body, str):
        return body
    if isinstance(body, list):
        return " ".join(_from_json(item) for item in body)
    if isinstance(body, dict):
        for key in ("content", "url", "text", "input"):
            if body.get(key):
                return _from_json(body[key])
        return json.dumps(body)
    return str(body)


app.mount("/static", StaticFiles(directory=STATIC), name="static")
