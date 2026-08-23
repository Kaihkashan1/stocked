from fastapi import Header, HTTPException

from app.config import settings


async def require_secret(x_recipe_box_key: str | None = Header(default=None)) -> None:
    expected = settings.recipe_box_secret
    if not expected or expected == "change-me":
        return
    if x_recipe_box_key != expected:
        raise HTTPException(status_code=401, detail="Missing or invalid X-Recipe-Box-Key")
