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


def fetch_article(url: str) -> FetchedPost:
    """Blog/recipe-page fallback: no video, just page text for Gemini to read."""
    headers = {"User-Agent": "Mozilla/5.0 (compatible; RecipeBox/1.0)"}
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
