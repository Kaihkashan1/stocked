from __future__ import annotations

import json
import logging
import os
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse, urlunparse

import httpx
import yt_dlp

from app.config import settings
from app.models import FetchedPost, FetchedSlide

logger = logging.getLogger(__name__)

URL_RE = re.compile(r"https?://\S+", re.IGNORECASE)
# Long food blogs put ads/intro/related posts before the recipe card. 6k
# chars was cutting RecipeTin Eats (and similar) off in the story, so Gemini
# only saw ingredient *names* and saved a recipe with no amounts.
ARTICLE_MAX_CHARS = 14000
_INGREDIENT_HEADING = re.compile(r"\bingredients\b", re.IGNORECASE)
# A real heading is reliably followed by a colon ("Ingredients:") once the
# page's whitespace has been flattened to a single line; a stray mid-sentence
# mention almost never is. Preferred over the bare _INGREDIENT_HEADING match
# when it exists — see _find_ingredient_heading.
_INGREDIENT_HEADING_COLON = re.compile(r"\bingredients\s*:", re.IGNORECASE)
APIFY_API_BASE = "https://api.apify.com/v2"
# Cap how many carousel stills we send to Gemini. Instagram's own limit is
# 10; some scrapers expose more, and 20 still fits a 300s Hobby run if
# each download is kept short.
MAX_CAROUSEL_IMAGES = 20
# Gemini accepts at most 10 videos per prompt; short carousel clips share
# that cap (Instagram sidecars are at most 10 items anyway).
MAX_CAROUSEL_VIDEOS = 10


def extract_url(text: str) -> str:
    """Pull the first URL out of Shortcut input (which is often messy).

    Not restricted to any one site: yt-dlp handles video/reel links from
    hundreds of hosts for free, and anything it doesn't recognize falls back
    to a plain-text article fetch in fetch_post().
    """
    match = URL_RE.search(text or "")
    if not match:
        raise ValueError(
            "No link found. Share a recipe reel, video, or blog post link."
        )
    return normalize_url(match.group(0).rstrip(").,]\"'"))


def normalize_url(url: str) -> str:
    parsed = urlparse(url.strip())
    # Drop tracking query params / fragments so the same reel dedupes.
    path = parsed.path.rstrip("/")
    return urlunparse((parsed.scheme, parsed.netloc.lower(), path, "", "", ""))


def _has_dedicated_extractor(url: str) -> bool:
    """True if yt-dlp has a site-specific extractor for this URL (Instagram,
    YouTube, TikTok, hundreds more) rather than only its generic page-scraper.
    Used to skip straight to the article-text fallback for plain blog links
    instead of wasting a request having yt-dlp's generic extractor try (and
    fail) to find an embedded video first."""
    try:
        from yt_dlp.extractor import gen_extractor_classes
    except ImportError:
        return True  # unknown yt-dlp version's internals; just try it
    for extractor in gen_extractor_classes():
        if extractor.ie_key() == "Generic":
            continue
        try:
            if extractor.suitable(url):
                return True
        except Exception:
            continue
    return False


def _ydl_opts(out_dir: Path, download: bool) -> dict:
    opts: dict = {
        "outtmpl": str(out_dir / "%(id)s.%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "noplaylist": True,
        "merge_output_format": "mp4",
        "skip_download": not download,
        "writethumbnail": True,
        "ignore_no_formats_error": True,
        # Empty string = direct connection. Dev shells often inject a proxy
        # that Instagram rejects with 403 on the CONNECT tunnel.
        "proxy": "",
    }
    if download:
        opts["format"] = "best[ext=mp4][height<=720]/best[height<=720]/best"
    return opts


def fetch_post(url: str, out_dir: Path) -> FetchedPost:
    """Download the reel/post/video. Anything yt-dlp doesn't recognize falls
    back to a plain-text article fetch — Gemini can extract a recipe from
    either a video+caption or plain article text.

    Instagram is handled entirely separately, through Apify — there is no
    cookie-based fallback. If Apify isn't configured or the fetch fails,
    that's a real, visible error rather than a silent degrade, since Apify
    is now the only way this app fetches Instagram content at all."""
    out_dir.mkdir(parents=True, exist_ok=True)
    url = normalize_url(url)

    if _is_instagram_url(url):
        if not settings.apify_api_token.strip():
            raise RuntimeError(
                "Instagram fetching needs an Apify token (APIFY_API_TOKEN) — there's no "
                "other way to fetch Instagram content in this app. See README."
            )
        apify_post = _fetch_instagram_via_apify(url, out_dir)
        if apify_post is None:
            raise RuntimeError(
                "Could not fetch that Instagram post via Apify. It may be private, "
                "deleted, or the actor had a transient failure — try again shortly."
            )
        return apify_post

    if not _has_dedicated_extractor(url):
        logger.info("No yt-dlp extractor for %s; treating as an article", url)
        return fetch_article(url)

    try:
        info = _extract(url, out_dir, download=False)
    except RuntimeError as exc:
        if "Unsupported URL" in str(exc):
            logger.info("yt-dlp rejected %s; treating as an article", url)
            return fetch_article(url)
        raise

    if _has_video_formats(info):
        try:
            info = _extract(url, out_dir, download=True)
        except RuntimeError as exc:
            logger.warning("Video download failed; using image/caption instead")
            logger.debug("%s", exc)

    video_path = _existing_media(out_dir, info, video=True)
    thumbnail_path = _existing_media(out_dir, info, video=False)
    if video_path is None and thumbnail_path is None:
        logger.warning("No video file; using post image/caption")
        _download_thumbnail(info, out_dir)
        thumbnail_path = _existing_media(out_dir, info, video=False)

    return FetchedPost(
        url=url,
        caption=(info.get("description") or info.get("title") or "").strip(),
        video_path=str(video_path) if video_path else None,
        thumbnail_path=str(thumbnail_path) if thumbnail_path else None,
        thumbnail_url=_thumbnail_url(info),
        media_id=str(info.get("id") or ""),
    )


def _is_instagram_url(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    return host == "instagram.com" or host.endswith(".instagram.com")


def get_apify_usage() -> dict | None:
    """Live monthly spend vs. Apify's platform credit limit, straight from
    Apify's own account API (GET /users/me/limits) — this app never tracks
    dollars itself, so the Settings "API usage" card can't drift from what
    Apify actually bills. Returns None (card should just omit itself rather
    than show a stale/fake number) if there's no token or the call fails."""
    token = settings.apify_api_token.strip()
    if not token:
        return None
    try:
        response = httpx.get(
            f"{APIFY_API_BASE}/users/me/limits",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        response.raise_for_status()
        data = response.json().get("data") or {}
        used = (data.get("current") or {}).get("monthlyUsageUsd")
        limit = (data.get("limits") or {}).get("maxMonthlyUsageUsd")
        if used is None or limit is None:
            return None
        result = {"used_usd": round(used, 2), "limit_usd": round(limit, 2)}
        # The end of the current cycle — Apify resets on the account's own
        # billing-cycle anniversary, not the 1st of the month, so this is
        # worth surfacing rather than assuming a fixed date.
        resets_at = (data.get("monthlyUsageCycle") or {}).get("endAt")
        if resets_at:
            result["resets_at"] = resets_at
        return result
    except Exception as exc:
        logger.info("Apify usage check skipped: %s", exc)
        return None


class ApifyLimitError(RuntimeError):
    """Apify's account-wide usage limit (monthly platform credit) was hit.
    Raised (not swallowed) so it surfaces as a real error instead of
    silently degrading, since there's no other way to fetch Instagram
    content in this app."""


# Substrings seen in a real reported Apify limit response ("Monthly usage
# hard limit exceeded" — github.com/apify/apify-mcp-server#263) or
# documented as the platform's own error type
# ("monthly-usage-hard-limit-exceeded"), plus generic related wording.
_APIFY_LIMIT_MARKERS = ("usage hard limit", "usage limit", "monthly usage", "insufficient", "free plan", "free tier")


def _looks_like_apify_limit(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in _APIFY_LIMIT_MARKERS)


def _fetch_more_comments(url: str, token: str, max_items: int = 15) -> list[dict]:
    """Fallback used only when the primary actor's own handful of comments
    (`firstComment`/`latestComments`) doesn't include the post owner's: a
    second Apify actor with a dedicated comments-search mode, returning up
    to 15 comments (free tier) sorted newest first — confirmed via a real
    case where the owner's actual recipe comment existed on the post but
    wasn't among the primary actor's own small sample.

    Best-effort — never raises, returns [] on any problem, since this is
    strictly extra reach for _pick_comment_text, not a requirement.

    Skipped entirely on Vercel: this is a second sequential network call on
    top of the primary post fetch, and /ingest has a hard 60s function
    budget there with no safe room left for it (see README).
    """
    if os.environ.get("VERCEL"):
        return []
    try:
        response = httpx.post(
            f"{APIFY_API_BASE}/acts/{settings.apify_comments_actor}/run-sync-get-dataset-items",
            headers={"Authorization": f"Bearer {token}"},
            json={"resultsType": "comments", "directUrls": [url], "resultsLimit": max_items},
            timeout=30,
        )
        response.raise_for_status()
        items = response.json()
        return [c for c in items if isinstance(c, dict) and c.get("text")] if isinstance(items, list) else []
    except Exception as exc:
        logger.info("Extra comments search skipped for %s: %s", url, exc)
        return []


def _pick_comment_text(item: dict, owner_username: str, url: str, token: str) -> str:
    """Some recipe accounts post the actual ingredients/steps as a
    follow-up comment rather than in the caption. The primary actor
    returns `firstComment` (the literal first comment on the post, author
    unknown) and `latestComments` (a handful of recent ones, each with an
    owner username) as part of the same post fetch — no separate call
    needed for the common case.

    Prefers the post owner's own comment — the far more reliable "this is
    the actual recipe continuation" signal than an early fan's "😍" —
    falling back to firstComment plus a couple of the most recent comments
    if the owner isn't among them. If the owner isn't in that first handful
    either, searches further via _fetch_more_comments before giving up —
    the primary actor's "a few" comments genuinely missed a real recipe
    comment that existed on the post (confirmed manually), so this isn't
    just theoretical.
    """
    latest = item.get("latestComments")
    latest = latest if isinstance(latest, list) else []

    owner_lower = (owner_username or "").lower()

    def owner_comments(pool: list[dict]) -> list[dict]:
        return [
            c for c in pool
            if isinstance(c, dict) and c.get("text") and (c.get("ownerUsername") or "").lower() == owner_lower
        ]

    from_owner = owner_comments(latest)
    if not from_owner:
        extra = _fetch_more_comments(url, token)
        if extra:
            latest = extra  # richer pool feeds both the owner search and the chronological fallback below
            from_owner = owner_comments(latest)

    if from_owner:
        from_owner.sort(key=lambda c: c.get("timestamp") or "")
        return "\n\n".join(f"Comment by @{c.get('ownerUsername')}: {c['text']}" for c in from_owner[:3])

    parts = []
    first_comment = (item.get("firstComment") or "").strip()
    if first_comment:
        parts.append(f"First comment: {first_comment}")
    for c in latest[:2]:
        if isinstance(c, dict) and c.get("text"):
            parts.append(f"Comment by @{c.get('ownerUsername') or 'unknown'}: {c['text']}")
    return "\n\n".join(parts)


def _fetch_instagram_via_apify(url: str, out_dir: Path) -> FetchedPost | None:
    """Caption + media + comments for a single Instagram post/reel via
    Apify's official instagram-post-scraper actor — no Instagram login
    involved at all, so it carries no risk to any Instagram account.
    Returns None on an ordinary/transient failure; raises ApifyLimitError
    when the failure looks like a usage-limit block, so that surfaces as a
    real error rather than a silent degrade.

    Chosen over the community (API Dojo) actors used earlier because this
    one is officially maintained by Apify, has a much larger track record
    (122K+ users vs. low thousands), is cheaper per post, and — critically —
    doesn't impose a "free users: 5 runs/month" throttle the way every
    API Dojo actor checked did. It also returns comments as part of the
    same request, so there's no second sequential call and no Vercel
    60-second-budget tradeoff to design around.

    Schema is per apify/instagram-post-scraper's documented output (not a
    contractual guarantee — it's a third-party scraper, same caveat as
    yt-dlp itself): {"caption": str, "videoUrl": str, "images": [str],
    "ownerUsername": str, "id"/"shortCode": str, "firstComment": str,
    "latestComments": [{"text": str, "ownerUsername": str, ...}]}.
    """
    token = settings.apify_api_token.strip()
    on_vercel = bool(os.environ.get("VERCEL"))
    # Hobby Fluid allows 300s. Keep Apify short enough that a reel
    # download + Gemini Files upload + generate_content still fit.
    apify_timeout = 45 if on_vercel else 60
    try:
        response = httpx.post(
            f"{APIFY_API_BASE}/acts/{settings.apify_instagram_actor}/run-sync-get-dataset-items",
            headers={"Authorization": f"Bearer {token}"},
            json={"username": [url], "resultsLimit": 1},
            timeout=apify_timeout,
        )
        response.raise_for_status()
        items = response.json()
    except httpx.HTTPStatusError as exc:
        body = exc.response.text or ""
        if _looks_like_apify_limit(body):
            raise ApifyLimitError(
                "Apify's monthly usage limit has been reached. The recipe wasn't "
                "fetched. It resets on your personal Apify billing-cycle date (Apify "
                "Console > Billing > Current period shows exactly when) — not the 1st "
                "of the calendar month — or you can upgrade your Apify plan sooner."
            ) from exc
        logger.warning("Apify Instagram fetch failed for %s: %s", url, body[:300])
        return None
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("Apify Instagram fetch failed for %s: %s", url, exc)
        return None

    if not items or not isinstance(items, list):
        logger.warning("Apify returned no results for %s", url)
        return None

    item = items[0]
    if item.get("error"):
        logger.warning("Apify returned an error item for %s: %s", url, item)
        return None

    caption = (item.get("caption") or "").strip()
    media_id = str(item.get("id") or item.get("shortCode") or "")
    owner_username = item.get("ownerUsername") or ""

    comments_text = _pick_comment_text(item, owner_username, url, token)
    if comments_text:
        caption = f"{caption}\n\n{comments_text}".strip()

    video_url = item.get("videoUrl")
    media_timeout = 40 if on_vercel else 60
    slide_timeout_image = 8 if on_vercel else 45
    slide_timeout_video = 10 if on_vercel else 45

    image_paths: list[Path] = []
    slides: list[FetchedSlide] = []
    video_path = None
    image_url = None

    sidecar = _sidecar_slide_urls(item)
    if sidecar:
        has_video = any(kind == "video" for kind, _ in sidecar)
        limit = MAX_CAROUSEL_VIDEOS if has_video else MAX_CAROUSEL_IMAGES
        for index, (kind, slide_url) in enumerate(sidecar[:limit]):
            if image_url is None and kind == "image":
                image_url = slide_url
            timeout = slide_timeout_video if kind == "video" else slide_timeout_image
            saved = _download_apify_media(
                slide_url,
                out_dir,
                media_id,
                video=(kind == "video"),
                timeout=timeout,
                name_suffix=f"_{index}",
            )
            if saved is None:
                continue
            slides.append(FetchedSlide(kind=kind, path=str(saved)))
            if kind == "video" and video_path is None:
                video_path = saved
            if kind == "image":
                image_paths.append(saved)
                if image_url is None:
                    image_url = slide_url
    elif video_url:
        video_path = _download_apify_media(
            video_url, out_dir, media_id, video=True, timeout=media_timeout
        )
        if video_path is not None:
            slides.append(FetchedSlide(kind="video", path=str(video_path)))
    else:
        for index, slide_url in enumerate(_carousel_image_urls(item)[:MAX_CAROUSEL_IMAGES]):
            if image_url is None:
                image_url = slide_url
            saved = _download_apify_media(
                slide_url,
                out_dir,
                media_id,
                video=False,
                timeout=slide_timeout_image,
                name_suffix=f"_{index}",
            )
            if saved is not None:
                image_paths.append(saved)
                slides.append(FetchedSlide(kind="image", path=str(saved)))

    thumbnail_path = image_paths[0] if image_paths else None

    if video_path is None and thumbnail_path is None and not caption and not slides:
        logger.warning("Apify result for %s had no caption or media", url)
        return None

    return FetchedPost(
        url=url,
        caption=caption,
        video_path=str(video_path) if video_path else None,
        thumbnail_path=str(thumbnail_path) if thumbnail_path else None,
        thumbnail_url=image_url,
        image_paths=[str(path) for path in image_paths],
        slides=slides,
        media_id=media_id,
    )


def _sidecar_slide_urls(item: dict) -> list[tuple[str, str]]:
    """Ordered (kind, url) for a multi-item Instagram post. Empty when this
    is a single reel or a stills-only carousel that only has `images`."""
    children = item.get("childPosts")
    if not isinstance(children, list) or len(children) < 2:
        return []
    slides: list[tuple[str, str]] = []
    for child in children:
        if not isinstance(child, dict):
            continue
        video = child.get("videoUrl")
        if isinstance(video, str) and video.strip():
            slides.append(("video", video.strip()))
            continue
        still = child.get("displayUrl") or child.get("imageUrl")
        if isinstance(still, str) and still.strip():
            slides.append(("image", still.strip()))
    return slides


def _carousel_image_urls(item: dict) -> list[str]:
    """Every still URL Apify exposes for a sidecar/carousel post, in order,
    de-duplicated. `images[0]` alone was dropping the rest of a recipe
    that's written across slides."""
    urls: list[str] = []
    seen: set[str] = set()

    def add(raw: object) -> None:
        if not isinstance(raw, str):
            return
        url = raw.strip()
        if url and url not in seen:
            seen.add(url)
            urls.append(url)

    images = item.get("images")
    if isinstance(images, list):
        for entry in images:
            if isinstance(entry, str):
                add(entry)
            elif isinstance(entry, dict):
                add(entry.get("url") or entry.get("imageUrl") or entry.get("displayUrl"))
    children = item.get("childPosts")
    if isinstance(children, list):
        for child in children:
            if isinstance(child, dict) and not child.get("videoUrl"):
                add(child.get("displayUrl") or child.get("imageUrl"))
    add(item.get("displayUrl"))
    return urls


def _download_apify_media(
    url: str,
    out_dir: Path,
    media_id: str,
    video: bool,
    timeout: int = 60,
    name_suffix: str = "",
) -> Path | None:
    dest = out_dir / f"{media_id or 'apify'}{name_suffix}{'.mp4' if video else '.jpg'}"
    try:
        with httpx.stream("GET", url, timeout=timeout, follow_redirects=True) as response:
            response.raise_for_status()
            with dest.open("wb") as f:
                for chunk in response.iter_bytes():
                    f.write(chunk)
        return dest
    except httpx.HTTPError as exc:
        logger.warning("Could not download Apify media (%s): %s", url, exc)
        return None


def fetch_article(url: str) -> FetchedPost:
    """Blog/recipe-page fallback: no video, just page text for Gemini to read.
    A self-identifying bot UA gets hard-blocked (403) by a lot of ordinary
    food-blog hosting (Wordfence, Cloudflare's basic bot rules, etc.) even
    for a single, personal, one-off fetch like this — so this mimics a
    real browser instead."""
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        ),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    }
    try:
        response = httpx.get(url, follow_redirects=True, timeout=20, headers=headers)
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise RuntimeError(f"Could not fetch that page. {exc}") from exc

    html = response.text
    structured = extract_jsonld_recipe_text(html)
    text = structured or clip_article_text(extract_article_text(html), ARTICLE_MAX_CHARS)
    if not text:
        raise RuntimeError("That page didn't have any readable text to extract a recipe from.")

    return FetchedPost(
        url=url,
        caption=text[:ARTICLE_MAX_CHARS],
        video_path=None,
        thumbnail_path=None,
        thumbnail_url=extract_og_image(html, url),
        media_id="",
    )


class _ArticleTextExtractor(HTMLParser):
    """Strips tags/scripts/styles down to plain text, stdlib only."""

    _SKIP_TAGS = {"script", "style", "noscript", "svg", "template"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self.chunks: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in self._SKIP_TAGS:
            self._skip_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in self._SKIP_TAGS and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._skip_depth == 0 and data.strip():
            self.chunks.append(data.strip())


def extract_article_text(html: str) -> str:
    parser = _ArticleTextExtractor()
    try:
        parser.feed(html)
    except Exception:
        logger.warning("Could not parse page HTML for article text")
        return ""
    return re.sub(r"\s+", " ", " ".join(parser.chunks)).strip()


def clip_article_text(text: str, limit: int) -> str:
    """Keep a window that includes the ingredients list when the page is long."""
    if not text or len(text) <= limit:
        return text
    match = _find_ingredient_heading(text)
    if not match:
        return text[:limit]
    start = max(0, match.start() - 400)
    return text[start : start + limit]


def _find_ingredient_heading(text: str) -> re.Match | None:
    """Distinguishing an actual "Ingredients" heading from a stray
    mid-sentence mention (e.g. "packed with wholesome ingredients...")
    matters: taking the first match unconditionally meant a blog that
    mentions the word once in its intro would anchor the extraction window
    right back near the top of the page, defeating the point of this
    function. Prefer a match followed by a colon — a real heading reads
    "Ingredients:" once whitespace is flattened, a passing mention doesn't.
    Within each tier the LAST match wins, not the first: recipe blogs put
    their story/SEO padding (which can itself contain an early, colon-suffixed
    false positive, e.g. "A note on ingredients: feel free to substitute...")
    before the actual card, so the final occurrence of either pattern is far
    more likely to be the real heading."""
    colon_matches = list(_INGREDIENT_HEADING_COLON.finditer(text))
    if colon_matches:
        return colon_matches[-1]
    matches = list(_INGREDIENT_HEADING.finditer(text))
    return matches[-1] if matches else None


def extract_jsonld_recipe_text(html: str) -> str:
    """schema.org Recipe blocks carry quantities even when the visible page
    buries the card under thousands of characters of intro."""
    blocks = re.findall(
        r'<script[^>]*type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    recipes: list[dict] = []
    for raw in blocks:
        try:
            data = json.loads(raw.strip())
        except json.JSONDecodeError:
            continue
        _collect_jsonld_recipes(data, recipes)
    if not recipes:
        return ""
    recipe = _select_primary_jsonld_recipe(recipes, html)
    ingredients = recipe.get("recipeIngredient") or []
    if not ingredients:
        return ""
    instruction_lines = _jsonld_instruction_lines(recipe.get("recipeInstructions"))
    if not instruction_lines:
        # Ingredients-only JSON-LD is worse than no JSON-LD at all: it wins
        # outright over the full-page fallback (see fetch_article's
        # `structured or clip_article_text(...)`), so returning it here would
        # leave a recipe saved with a complete ingredient list and silently
        # zero steps, no error surfaced. Falling through to the full-page
        # text at least gives the steps — likely written in prose — a
        # chance of being read.
        return ""
    lines = [
        f"Title: {recipe.get('name') or ''}".strip(),
        f"Servings: {_jsonld_yield(recipe)}".strip(),
        "Ingredients:",
        *[f"- {_plain_jsonld_text(item)}" for item in ingredients if _plain_jsonld_text(item)],
        "Steps:",
        *instruction_lines,
    ]
    text = "\n".join(line for line in lines if line and line not in {"Title:", "Servings:", "Steps:"})
    logger.info("Using JSON-LD recipe with %s ingredient lines and %s steps", len(ingredients), len(instruction_lines))
    return text.strip()


def _select_primary_jsonld_recipe(recipes: list[dict], html: str) -> dict:
    """Multiple schema.org Recipe blocks on one page — a "3 ways to make X"
    roundup, or embedded widget recipes from an ad network — shouldn't be
    resolved by "whichever has the most ingredients" alone: that can
    silently pick a minor variation over the page's actual subject. Prefer
    whichever recipe's name matches the page's <title>; only fall back to
    the ingredient-count heuristic when there's no clear match (or there's
    just one recipe, where the question doesn't arise).

    The title match has to be unambiguous to be trusted: a short, generic
    recipe name (e.g. "Cookies") can be a substring of an unrelated page
    title purely by chance. If more than one recipe's name matches, that's
    a sign the substring check isn't discriminating and we fall through to
    the ingredient-count heuristic instead of guessing which match is real."""
    if len(recipes) == 1:
        return recipes[0]
    page_title = _extract_page_title(html)
    if page_title:
        matches = [
            recipe
            for recipe in recipes
            if (name := str(recipe.get("name") or "").strip().lower())
            and (name in page_title or page_title in name)
        ]
        if len(matches) == 1:
            return matches[0]
    return max(recipes, key=lambda item: len(item.get("recipeIngredient") or []))


def _extract_page_title(html: str) -> str:
    match = re.search(r"<title[^>]*>(.*?)</title>", html, flags=re.IGNORECASE | re.DOTALL)
    if not match:
        return ""
    return re.sub(r"\s+", " ", match.group(1)).strip().lower()


def _collect_jsonld_recipes(node, acc: list[dict]) -> None:
    if isinstance(node, list):
        for item in node:
            _collect_jsonld_recipes(item, acc)
        return
    if not isinstance(node, dict):
        return
    types = node.get("@type")
    names = _jsonld_type_names(types)
    if "Recipe" in names:
        acc.append(node)
    graph = node.get("@graph")
    if graph is not None:
        _collect_jsonld_recipes(graph, acc)
    for key, value in node.items():
        if key in {"@graph", "@type", "@context"}:
            continue
        if isinstance(value, (dict, list)):
            _collect_jsonld_recipes(value, acc)


def _jsonld_type_names(types) -> list[str]:
    names = types if isinstance(types, list) else [types]
    return [str(name).rsplit("/", 1)[-1] for name in names if name]


def _jsonld_yield(recipe: dict) -> str:
    value = recipe.get("recipeYield") or recipe.get("yield") or ""
    if isinstance(value, list):
        value = next((item for item in value if item), "")
    return _plain_jsonld_text(value)


def _jsonld_instruction_lines(raw) -> list[str]:
    texts = _flatten_jsonld_instructions(raw)
    return [f"{index}. {text}" for index, text in enumerate(texts, start=1)]


def _flatten_jsonld_instructions(raw) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, str):
        text = re.sub(r"\s+", " ", raw).strip()
        return [text] if text else []
    if isinstance(raw, list):
        lines: list[str] = []
        for item in raw:
            lines.extend(_flatten_jsonld_instructions(item))
        return lines
    if isinstance(raw, dict):
        types = raw.get("@type")
        names = _jsonld_type_names(types)
        if "HowToSection" in names:
            heading = _plain_jsonld_text(raw.get("name"))
            nested = _flatten_jsonld_instructions(raw.get("itemListElement") or raw.get("itemList"))
            return ([heading] + nested) if heading else nested
        text = _plain_jsonld_text(raw.get("text") or raw.get("name"))
        return [text] if text else []
    return []


def _plain_jsonld_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return re.sub(r"\s+", " ", value).strip()
    if isinstance(value, dict):
        return _plain_jsonld_text(value.get("text") or value.get("name") or value.get("@value"))
    if isinstance(value, list):
        return ", ".join(part for item in value if (part := _plain_jsonld_text(item)))
    return str(value).strip()


def extract_og_image(html: str, base_url: str) -> str | None:
    match = re.search(
        r'<meta[^>]+(?:property|name)=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']',
        html,
        re.IGNORECASE,
    )
    if not match:
        return None
    from urllib.parse import urljoin

    return urljoin(base_url, match.group(1))


def _extract(url: str, out_dir: Path, download: bool) -> dict:
    opts = _ydl_opts(out_dir, download=download)
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=download)
        if not info:
            raise RuntimeError("Could not fetch the Instagram post (empty response).")
        return _unwrap(info)
    except yt_dlp.utils.DownloadError as exc:
        detail = str(exc).strip().replace("\n", " ")
        raise RuntimeError(f"Could not fetch the Instagram post. {detail[:500]}") from exc


def _has_video_formats(info: dict) -> bool:
    video_exts = {"mp4", "m4v", "mov", "webm", "mkv"}
    for fmt in info.get("formats") or []:
        ext = (fmt.get("ext") or "").lower()
        vcodec = fmt.get("vcodec")
        if ext in video_exts or (vcodec and vcodec != "none"):
            return True
    return (info.get("ext") or "").lower() in video_exts


def _unwrap(info: dict) -> dict:
    if info.get("_type") in {"playlist", "multi_video"}:
        for entry in info.get("entries") or []:
            if entry:
                return entry
    return info


def _thumbnail_url(info: dict) -> str | None:
    if info.get("thumbnail"):
        return info["thumbnail"]
    for thumb in reversed(info.get("thumbnails") or []):
        if thumb.get("url"):
            return thumb["url"]
    return None


def _download_thumbnail(info: dict, out_dir: Path) -> None:
    thumb = _thumbnail_url(info)
    if not thumb:
        return
    dest = out_dir / f"{info.get('id', 'thumb')}.jpg"
    if dest.exists():
        return
    try:
        import urllib.request

        urllib.request.urlretrieve(thumb, dest)
    except Exception:
        logger.warning("Could not save the post image")


def _existing_media(out_dir: Path, info: dict, video: bool) -> Path | None:
    if not out_dir.exists():
        return None
    media_id = str(info.get("id") or "")
    video_exts = {".mp4", ".mkv", ".webm", ".mov"}
    image_exts = {".jpg", ".jpeg", ".png", ".webp"}
    wanted = video_exts if video else image_exts
    if media_id:
        for path in out_dir.iterdir():
            if path.stem.startswith(media_id) and path.suffix.lower() in wanted:
                return path
    # Last resort: any matching file we just wrote.
    matches = [p for p in out_dir.iterdir() if p.suffix.lower() in wanted]
    return matches[0] if matches else None
