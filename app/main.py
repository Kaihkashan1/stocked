from __future__ import annotations

import asyncio
import json
import logging
import os
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from google.genai.errors import APIError as GeminiAPIError

from app.auth import require_secret
from app.config import ROOT, settings
from app.errors import (
    GEMINI_DAILY_QUOTA,
    NOT_A_RECIPE_MESSAGE,
    REQUEST_TIMEOUT_MESSAGE,
    friendly_message,
    gemini_is_busy,
)
from app.extract import extract_recipe
from app.fetch import extract_url, get_apify_usage
from app.match import STAPLES, collapse_catalog, grouped_pantry
from app.models import (
    FetchedPost,
    MedicinesUpdate,
    PantryInventoryUpdate,
    PantryUpdate,
    RecipeCreate,
    RecipeUpdate,
    ToBuySourceChange,
    ToBuyUpdate,
)
from app.pipeline import jobs, process_recipe
from app.store import (
    MEDICINE_CATEGORIES,
    add_to_buy_source,
    create_recipe,
    delete_recipe,
    get_gemini_reads_today,
    get_have_items,
    get_medicines,
    get_pantry_categories,
    get_pantry_inventory,
    get_recent_imports,
    get_recipe,
    get_to_buy_items,
    ingredient_strings,
    list_recipes,
    log_import,
    remove_to_buy_source,
    save_have_items,
    save_medicines,
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
        "Curry and Cask ready  model=%s  sheet=%s  apify=%s",
        settings.gemini_model,
        "yes" if settings.google_sheet_id else "MISSING",
        "yes" if settings.apify_api_token.strip() else "MISSING",
    )
    if not settings.gemini_api_key:
        logger.warning("GEMINI_API_KEY is not set")
    if not settings.has_service_account():
        logger.warning("Service account is missing (file or GOOGLE_SERVICE_ACCOUNT_JSON)")
    yield


app = FastAPI(title="Curry and Cask", lifespan=lifespan)


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
    catalog = collapse_catalog(sorted(items, key=str.lower))
    return {"recipes": recipes, "pantry": grouped_pantry(catalog)}


@app.get("/api/recipes/{row_id}")
async def api_get_recipe(row_id: int):
    recipe = get_recipe(row_id)
    if not recipe:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return _public(recipe)


MAX_PHOTO_BYTES = 4 * 1024 * 1024  # Vercel's request body limit is ~4.5MB; stay under it.


@app.post("/api/recipes", dependencies=[Depends(require_secret)])
async def api_create_recipe(request: Request):
    """JSON body for a typed-in recipe; multipart (`recipe` JSON + `photo`
    file) when saving a photo extraction so the original still is kept."""
    photo_bytes = None
    ctype = request.headers.get("content-type", "")
    try:
        if "multipart/form-data" in ctype:
            form = await request.form()
            raw = form.get("recipe")
            if not raw:
                raise HTTPException(status_code=400, detail="Missing recipe")
            payload = raw if isinstance(raw, str) else str(raw)
            body = RecipeCreate.model_validate_json(payload)
            upload = form.get("photo")
            if upload is not None and hasattr(upload, "read"):
                photo_bytes = await upload.read()
                if len(photo_bytes) > MAX_PHOTO_BYTES:
                    raise HTTPException(status_code=413, detail="That photo is too large. Please use a smaller image.")
        else:
            body = RecipeCreate.model_validate(await request.json())
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Could not read that recipe.") from exc

    try:
        created = create_recipe(**body.model_dump(), photo_bytes=photo_bytes)
    except Exception as exc:
        from app.photos import PhotoStoreError

        if isinstance(exc, PhotoStoreError):
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        logger.exception("Could not save recipe")
        raise HTTPException(status_code=502, detail="Could not save that recipe. Try again.") from exc
    if not created:
        raise HTTPException(status_code=502, detail="Could not save recipe")
    return _public(created)


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
        log_import(None, "error", NOT_A_RECIPE_MESSAGE, used_backup=used_backup)
        raise HTTPException(status_code=502, detail=NOT_A_RECIPE_MESSAGE)
    recipe = recipes[0]
    log_import(None, "saved", recipe.title, used_backup=used_backup)

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
async def api_update_recipe(row_id: int, request: Request):
    # JSON for a normal edit; multipart when replacing or removing the
    # original photo (`recipe` JSON + optional `photo` file + `clear_photo`).
    photo_bytes = None
    clear_photo = False
    ctype = request.headers.get("content-type", "")
    try:
        if "multipart/form-data" in ctype:
            form = await request.form()
            raw = form.get("recipe") or "{}"
            payload = raw if isinstance(raw, str) else str(raw)
            body = RecipeUpdate.model_validate_json(payload)
            clear_photo = str(form.get("clear_photo") or "").strip().lower() in {"1", "true", "yes"}
            upload = form.get("photo")
            if upload is not None and hasattr(upload, "read"):
                photo_bytes = await upload.read()
                if len(photo_bytes) > MAX_PHOTO_BYTES:
                    raise HTTPException(status_code=413, detail="That photo is too large. Please use a smaller image.")
        else:
            body = RecipeUpdate.model_validate(await request.json())
            clear_photo = bool(body.clear_photo)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Could not read that recipe.") from exc

    fields = body.model_dump(exclude_unset=True, exclude={"clear_photo"})
    try:
        updated = update_recipe(row_id, **fields, photo_bytes=photo_bytes, clear_photo=clear_photo)
    except Exception as exc:
        from app.photos import PhotoStoreError

        if isinstance(exc, PhotoStoreError):
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        logger.exception("Could not update recipe %s", row_id)
        raise HTTPException(status_code=502, detail="Could not save that recipe. Try again.") from exc
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
    items = get_pantry_inventory()
    return {"items": items, "categories": get_pantry_categories(items)}


@app.put("/api/pantry-inventory", dependencies=[Depends(require_secret)])
async def api_put_pantry_inventory(body: PantryInventoryUpdate):
    return save_pantry_inventory(body.items, categories=body.categories)


@app.get("/api/to-buy")
async def api_get_to_buy():
    return {"items": get_to_buy_items()}


@app.put("/api/to-buy", dependencies=[Depends(require_secret)])
async def api_put_to_buy(body: ToBuyUpdate):
    return {"items": save_to_buy_items(body.items)}


@app.post("/api/to-buy/source", dependencies=[Depends(require_secret)])
async def api_add_to_buy_source(body: ToBuySourceChange):
    return {
        "items": add_to_buy_source(
            body.text, qty=body.qty, recipe_id=body.recipe_id, category=body.category, notes=body.notes
        )
    }


@app.post("/api/to-buy/source/remove", dependencies=[Depends(require_secret)])
async def api_remove_to_buy_source(body: ToBuySourceChange):
    return {"items": remove_to_buy_source(body.text, recipe_id=body.recipe_id)}


@app.get("/api/medicines")
async def api_get_medicines():
    """The Medicines-tab cabinet — a sibling of /api/pantry-inventory with
    its own fields (dosage, prescriber, purpose) and a fixed category list
    instead of the grocery aisle taxonomy."""
    return {"items": get_medicines(), "categories": list(MEDICINE_CATEGORIES)}


@app.put("/api/medicines", dependencies=[Depends(require_secret)])
async def api_put_medicines(body: MedicinesUpdate):
    return {"items": save_medicines(body.items), "categories": list(MEDICINE_CATEGORIES)}


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
        return await _ingest_watching_client(request, content, process_recipe)
    background_tasks.add_task(process_recipe, content)
    return {"status": "queued", "message": "Saving… I'll add it to your sheet shortly."}


async def _ingest_watching_client(request: Request, content: str, processor=process_recipe) -> dict:
    """Run ingest off the event loop so a Shortcut hang-up can be logged.

    process_recipe is blocking. If it ran inline, the phone closing the
    HTTP request (Shortcuts timeout) would never be observed, and ImportLog
    would stay empty whenever Vercel then killed the function.
    """
    try:
        url = extract_url(content)
    except Exception:
        url = None
    task = asyncio.create_task(asyncio.to_thread(processor, content))
    logged_timeout = False
    while not task.done():
        if not logged_timeout and await request.is_disconnected():
            logged_timeout = True
            log_import(url, "error", REQUEST_TIMEOUT_MESSAGE)
        try:
            return await asyncio.wait_for(asyncio.shield(task), timeout=0.5)
        except TimeoutError:
            continue
    return task.result()


@app.get("/api/recipes/{row_id}/photo")
async def api_recipe_photo(row_id: int):
    recipe = get_recipe(row_id)
    photo_id = str((recipe or {}).get("photo_id") or "").strip()
    if not recipe or not photo_id:
        raise HTTPException(status_code=404, detail="Photo not found")
    try:
        from app.photos import PhotoStoreError, download_recipe_photo

        data, content_type = download_recipe_photo(photo_id)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="Photo not found") from None
    except Exception as exc:
        from app.photos import PhotoStoreError

        if isinstance(exc, PhotoStoreError):
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        raise
    return Response(
        content=data,
        media_type=content_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )



def _public(recipe: dict) -> dict:
    out = {key: value for key, value in recipe.items() if not key.endswith("_text") and key != "photo_id"}
    if recipe.get("photo_id"):
        out["photo_url"] = f"/api/recipes/{recipe['id']}/photo"
    return out



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
