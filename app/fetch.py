from __future__ import annotations

import logging
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


def _pick_comment_text(item: dict, owner_username: str) -> str:
    """Some recipe accounts post the actual ingredients/steps as a
    follow-up comment rather than in the caption. This actor returns
    `firstComment` (the literal first comment on the post, author unknown)
    and `latestComments` (a handful of recent ones, each with an owner
    username) as part of the same post fetch — no separate call needed.

    Prefers the post owner's own comment among latestComments — the far
    more reliable "this is the actual recipe continuation" signal than an
    early fan's "😍" — falling back to firstComment plus a couple of the
    most recent comments if the owner isn't among them.

    Heuristic, not a guarantee: latestComments is only "a few" recent
    comments per the actor's own docs, so on an old, very popular post the
    owner's original comment may no longer be among the "latest", and
    firstComment's author is unknown so it might not be the owner either.
    """
    latest = item.get("latestComments")
    latest = latest if isinstance(latest, list) else []

    owner_lower = (owner_username or "").lower()
    from_owner = [
        c for c in latest
        if isinstance(c, dict) and c.get("text") and (c.get("ownerUsername") or "").lower() == owner_lower
    ]
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
    try:
        response = httpx.post(
            f"{APIFY_API_BASE}/acts/{settings.apify_instagram_actor}/run-sync-get-dataset-items",
            headers={"Authorization": f"Bearer {token}"},
            json={"username": [url], "resultsLimit": 1},
            timeout=60,
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

    comments_text = _pick_comment_text(item, owner_username)
    if comments_text:
        caption = f"{caption}\n\n{comments_text}".strip()

    video_url = item.get("videoUrl")
    image_url = None
    if not video_url:
        images = item.get("images")
        if isinstance(images, list) and images:
            image_url = images[0]
        image_url = image_url or item.get("displayUrl")

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
