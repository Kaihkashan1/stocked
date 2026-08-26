from __future__ import annotations

import logging
import os
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse, urlunparse

import httpx
import yt_dlp

from app.config import settings
from app.models import FetchedPost

logger = logging.getLogger(__name__)

URL_RE = re.compile(r"https?://\S+", re.IGNORECASE)
ARTICLE_MAX_CHARS = 6000
APIFY_API_BASE = "https://api.apify.com/v2"


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
    cookie_file = settings.cookies_file_path()
    browser = settings.ytdlp_cookies_from_browser.strip().lower()
    if cookie_file:
        opts["cookiefile"] = str(cookie_file)
    elif browser:
        opts["cookiesfrombrowser"] = (browser,)
    return opts


def fetch_post(url: str, out_dir: Path) -> FetchedPost:
    """Download the reel/post/video. Anything yt-dlp doesn't recognize falls
    back to a plain-text article fetch — Gemini can extract a recipe from
    either a video+caption or plain article text."""
    out_dir.mkdir(parents=True, exist_ok=True)
    url = normalize_url(url)

    if _is_instagram_url(url) and settings.apify_api_token.strip():
        apify_post = _fetch_instagram_via_apify(url, out_dir)
        if apify_post is not None:
            return apify_post
        logger.info("Apify fetch didn't pan out for %s; falling back to yt-dlp", url)

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


class ApifyLimitError(RuntimeError):
    """Apify's usage limit was hit — either the account's monthly platform
    credit or this specific actor's own free-tier run cap. Raised (not
    swallowed) so it surfaces as a real error instead of silently falling
    back to Instagram cookies, which would quietly reintroduce the exact
    account risk this integration exists to avoid."""


# Substrings seen in real Apify limit responses (e.g. "Monthly usage hard
# limit exceeded" — github.com/apify/apify-mcp-server#263) or documented as
# the platform's own error type ("monthly-usage-hard-limit-exceeded"),
# plus generic terms for an actor's own self-imposed free-tier cap, which
# has no standardized wording since each actor author writes its own.
_APIFY_LIMIT_MARKERS = ("usage hard limit", "usage limit", "monthly usage", "insufficient", "free plan", "free tier")


def _looks_like_apify_limit(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in _APIFY_LIMIT_MARKERS)


def _fetch_instagram_comments(url: str, token: str, owner_username: str, max_items: int = 15) -> str:
    """Best-effort extra context: some recipe accounts post the actual
    ingredients/steps as a follow-up comment rather than in the caption.
    Fetches top-level comments (15/post is free) via a companion Apify
    actor, prefers the post owner's own comments — the likely recipe
    continuation — over an early commenter's "😍", falling back to the
    first couple of comments chronologically if the owner didn't comment.

    Never raises and never counts as a hard failure: this is a nice-to-have
    on top of the caption, not something worth failing the whole save over,
    so any problem here (including hitting this actor's own usage limit)
    is just logged and skipped rather than surfaced like the main post
    fetch's ApifyLimitError.

    Kept on a short timeout deliberately: this is a second sequential,
    community-actor call (observed taking anywhere from ~15s to a full
    timeout) stacked on top of the main post fetch, and /ingest has a hard
    60s ceiling on Vercel — this must not be the thing that blows that
    budget, even at the cost of sometimes missing a slow comment fetch.
    """
    # Wrapped as one broad try/except — this is a nice-to-have side channel,
    # so any surprise here (network, bad JSON, unexpected field shapes from
    # an unofficial actor) should degrade to "no extra context", never
    # bubble up and fail the save.
    try:
        response = httpx.post(
            f"{APIFY_API_BASE}/acts/{settings.apify_comments_actor}/run-sync-get-dataset-items",
            headers={"Authorization": f"Bearer {token}"},
            json={"startUrls": [url], "fetchReplies": False, "maxItems": max_items},
            timeout=25,
        )
        response.raise_for_status()
        items = response.json()
        if not isinstance(items, list):
            return ""

        comments = [item for item in items if isinstance(item, dict) and item.get("type") == "comment" and item.get("message")]
        if not comments:
            return ""
        comments.sort(key=lambda c: c.get("createdAt") or "")

        owner_lower = owner_username.lower()
        from_owner = [c for c in comments if ((c.get("user") or {}).get("username") or "").lower() == owner_lower]
        chosen = from_owner or comments[:2]

        return "\n\n".join(
            f"Comment by @{(c.get('user') or {}).get('username') or 'unknown'}: {c['message']}" for c in chosen[:5]
        )
    except Exception as exc:
        logger.info("Skipping comments for %s: %s", url, exc)
        return ""


def _fetch_instagram_via_apify(url: str, out_dir: Path) -> FetchedPost | None:
    """Caption + media for a single Instagram post/reel via a paid Apify
    actor instead of yt-dlp + personal cookies — no Instagram login involved
    at all, so it carries no risk to any Instagram account. Returns None on
    an ordinary/transient failure so fetch_post() falls back to the
    yt-dlp+cookies path; raises ApifyLimitError instead when the failure
    looks like a usage-limit block, so that one surfaces as a real error
    rather than a silent, risk-reintroducing fallback.

    Schema is per apidojo/instagram-scraper-api's documented output (not
    guaranteed by any contract — it's an unofficial community actor, same
    caveat as yt-dlp itself): {"caption": str, "isVideo": bool,
    "video": {"url": str}, "image"/"displayUrl": str, "id"/"code": str}.
    """
    token = settings.apify_api_token.strip()
    try:
        response = httpx.post(
            f"{APIFY_API_BASE}/acts/{settings.apify_instagram_actor}/run-sync-get-dataset-items",
            headers={"Authorization": f"Bearer {token}"},
            json={"startUrls": [url], "maxItems": 1},
            timeout=60,
        )
        response.raise_for_status()
        items = response.json()
    except httpx.HTTPStatusError as exc:
        body = exc.response.text or ""
        if _looks_like_apify_limit(body):
            raise ApifyLimitError(
                "Apify's usage limit has been reached (monthly platform credit, or this "
                "actor's own free-tier run cap). The recipe wasn't fetched. Wait for next "
                "month's reset, upgrade your Apify plan, or fall back to Instagram cookies "
                "(see README)."
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
    if item.get("noResults") or item.get("error"):
        logger.warning("Apify returned an error item for %s: %s", url, item)
        return None

    caption = (item.get("caption") or "").strip()
    media_id = str(item.get("id") or item.get("code") or "")
    owner_username = (item.get("owner") or {}).get("username", "")

    # Skipped entirely on Vercel: the main post fetch alone has been
    # observed taking the full 60s a couple of times, which is /ingest's
    # whole function budget there — a second sequential call has no safe
    # room left, not even on a short timeout. Fine locally / in a
    # background task, where nothing enforces that ceiling.
    if not os.environ.get("VERCEL"):
        comments_text = _fetch_instagram_comments(url, token, owner_username)
        if comments_text:
            caption = f"{caption}\n\n{comments_text}".strip()

    video_url = None
    video = item.get("video")
    if item.get("isVideo") and isinstance(video, dict):
        video_url = video.get("url")

    image_url = None
    if not video_url:
        image = item.get("image")
        if isinstance(image, dict):
            image_url = image.get("url")
        elif isinstance(image, str):
            image_url = image
        image_url = image_url or item.get("displayUrl") or item.get("thumbnailUrl")

    video_path = _download_apify_media(video_url, out_dir, media_id, video=True) if video_url else None
    thumbnail_path = _download_apify_media(image_url, out_dir, media_id, video=False) if image_url else None

    if video_path is None and thumbnail_path is None and not caption:
        logger.warning("Apify result for %s had no caption or media", url)
        return None

    return FetchedPost(
        url=url,
        caption=caption,
        video_path=str(video_path) if video_path else None,
        thumbnail_path=str(thumbnail_path) if thumbnail_path else None,
        thumbnail_url=image_url,
        media_id=media_id,
    )


def _download_apify_media(url: str, out_dir: Path, media_id: str, video: bool) -> Path | None:
    dest = out_dir / f"{media_id or 'apify'}{'.mp4' if video else '.jpg'}"
    try:
        with httpx.stream("GET", url, timeout=60, follow_redirects=True) as response:
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
    text = extract_article_text(html)
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
