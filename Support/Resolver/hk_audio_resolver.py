import json
import os
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

import certifi
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError


os.environ["SSL_CERT_FILE"] = certifi.where()


class ResolverError(Exception):
    pass


class ResolverLog:
    def __init__(self):
        self.messages = []

    def debug(self, _message):
        pass

    def warning(self, message):
        self.messages.append(message)

    error = warning


def https_url(address):
    if not isinstance(address, str):
        return None
    try:
        parts = urlsplit(address)
        if parts.scheme == "https" and parts.hostname and parts.username is None and parts.password is None:
            return parts
    except ValueError:
        pass
    return None


def extract(address, *, flat=False):
    logger = ResolverLog()
    with tempfile.TemporaryDirectory(prefix="hkotuner-audio-") as scratch:
        settings = {
            "quiet": True,
            "logger": logger,
            "cachedir": False,
            "noplaylist": True,
            "extract_flat": "in_playlist" if flat else False,
            "skip_download": True,
            "socket_timeout": 12,
            "retries": 0,
            "extractor_retries": 0,
            "js_runtimes": {},
            "remote_components": set(),
            # Metadata extraction must not try to launch FFmpeg.
            "ffmpeg_location": str(Path(scratch) / "missing-ffmpeg"),
        }
        try:
            with YoutubeDL(settings) as resolver:
                return resolver.extract_info(address, download=False)
        except DownloadError as failure:
            detail = " ".join([str(failure), *logger.messages]).lower()
            if "not a bot" in detail:
                raise ResolverError("bot_check") from None
            if "429" in detail:
                raise ResolverError("rate_limited") from None
            raise ResolverError("unavailable") from None


def resolve(address):
    parts = https_url(address)
    if not parts or parts.hostname not in {
        "youtube.com", "www.youtube.com", "music.youtube.com", "youtu.be", "soundcloud.com",
    }:
        raise ResolverError("unsupported_link")
    info = extract(address)
    for audio in reversed(info.get("formats", [])):
        protocol = audio.get("protocol") or ""
        if (audio.get("vcodec") == "none"
                and audio.get("acodec", "none") != "none"
                and not audio.get("has_drm")
                and "preview" not in (audio.get("format_id") or "").lower()
                and https_url(audio.get("url"))
                and (protocol.startswith("m3u8") or audio.get("ext") in {"m4a", "mp3", "aac"})):
            return {"url": audio["url"], "format": audio.get("ext"), "protocol": protocol}
    raise ResolverError("no_audio_format")


def search_soundcloud(query):
    phrase = query.strip()[:200]
    if not phrase:
        return []
    info = extract(f"scsearch20:{phrase}", flat=True)
    tracks = []
    for item in info.get("entries", []):
        if not item:
            continue
        address = item.get("webpage_url")
        parts = https_url(address)
        if not parts or parts.hostname != "soundcloud.com" or not item.get("title"):
            continue
        tracks.append({
            "id": f"sc:{address}",
            "source": "soundcloud",
            "title": item["title"],
            "artist": item.get("uploader") or "SoundCloud",
            "url": address,
            "duration": item.get("duration"),
            "thumbnail": item.get("thumbnail"),
        })
    return tracks


def request(raw):
    try:
        payload = json.loads(raw)
        if payload["operation"] == "resolve":
            response = resolve(payload["value"])
        elif payload["operation"] == "search":
            response = {"tracks": search_soundcloud(payload["value"])}
        else:
            response = {"error": "unsupported_operation"}
    except ResolverError as failure:
        response = {"error": str(failure)}
    except Exception:
        response = {"error": "runtime_error"}
    return json.dumps(response, ensure_ascii=False)
