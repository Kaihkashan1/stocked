from __future__ import annotations

import json
import logging
import os
from contextlib import asynccontextmanager
from typing import Any

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from app.auth import require_secret
from app.config import ROOT, settings
from app.match import STAPLES, grouped_pantry
from app.models import PlanUpdate, RecipeCreate, RecipeUpdate
from app.pipeline import jobs, process_recipe
from app.store import (
    create_recipe,
    delete_recipe,
    get_plan_ids,
    get_recipe,
    list_recipes,
    save_plan_ids,
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
        "Recipe Box ready  model=%s  sheet=%s  cookies=%s",
        settings.gemini_model,
        "yes" if settings.google_sheet_id else "MISSING",
        settings.ytdlp_cookies_from_browser
        or settings.ytdlp_cookies_file
        or ("env" if settings.ytdlp_cookies.strip() else "none"),
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
    items = sorted(
        {
            item
            for recipe in recipes
            for item in recipe.get("pantry") or []
            if item not in STAPLES
        },
        key=str.lower,
    )
    return {"recipes": recipes, "pantry": grouped_pantry(items)}


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


@app.patch("/api/recipes/{row_id}", dependencies=[Depends(require_secret)])
async def api_update_recipe(row_id: int, body: RecipeUpdate):
    if not get_recipe(row_id):
        raise HTTPException(status_code=404, detail="Recipe not found")
    updated = update_recipe(row_id, **body.model_dump(exclude_unset=True))
    if not updated:
        raise HTTPException(status_code=404, detail="Recipe not found")
    return _public(updated)


@app.delete("/api/recipes/{row_id}", dependencies=[Depends(require_secret)])
async def api_delete_recipe(row_id: int):
    if not delete_recipe(row_id):
        raise HTTPException(status_code=404, detail="Recipe not found")
    return {"status": "deleted", "id": row_id}


@app.get("/api/plan")
async def api_get_plan():
    return {"ids": get_plan_ids()}


@app.put("/api/plan", dependencies=[Depends(require_secret)])
async def api_put_plan(body: PlanUpdate):
    return {"ids": save_plan_ids(body.ids)}


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
