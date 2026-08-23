from __future__ import annotations

import logging
import re
from pathlib import Path
from urllib.parse import urlparse, urlunparse

import yt_dlp

from app.config import settings
from app.models import FetchedPost

logger = logging.getLogger(__name__)

INSTAGRAM_RE = re.compile(
    r"https?://(?:www\.)?(?:instagram\.com|instagr\.am)/[^\s]+",
    re.IGNORECASE,
)


def extract_instagram_url(text: str) -> str:
    """Pull the first Instagram URL out of Shortcut input (which is often messy)."""
    match = INSTAGRAM_RE.search(text or "")
    if not match:
        raise ValueError(
            "No Instagram URL found. This version only handles reels and posts — "
            "share a reel, post, or profile link from Instagram."
        )
    return normalize_url(match.group(0).rstrip(").,]\"'"))


def normalize_url(url: str) -> str:
    parsed = urlparse(url.strip())
    # Drop tracking query params / fragments so the same reel dedupes.
    path = parsed.path.rstrip("/")
    return urlunparse((parsed.scheme, parsed.netloc.lower(), path, "", "", ""))


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
    """Download the reel/post. Fall back to caption + thumbnail if video fails."""
    out_dir.mkdir(parents=True, exist_ok=True)
    url = normalize_url(url)

    info = _extract(url, out_dir, download=False)
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
