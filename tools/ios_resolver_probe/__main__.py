import json
import os
import ssl
import sys
import tempfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import certifi
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError
from yt_dlp.version import __version__


TRACKS = {
    "youtube_music": "https://music.youtube.com/watch?v=KLbkyunVsnY",
    "soundcloud": "https://soundcloud.com/forss/flickermood",
}


class ExternalProcessError(RuntimeError):
    pass


class ProbeLogger:
    def __init__(self):
        self.warnings = []

    def debug(self, _message):
        pass

    def warning(self, message):
        self.warnings.append(message)

    def error(self, message):
        self.warnings.append(message)


def deny_external_process(event, _args):
    if event in {"subprocess.Popen", "os.system", "os.exec", "os.spawn", "os.posix_spawn", "os.fork"}:
        raise ExternalProcessError("External processes are unavailable")


def extraction_error(error, warnings):
    message = " ".join([str(error), *warnings]).lower()
    if "not a bot" in message:
        return "bot_check"
    if "javascript runtime" in message or "challenge solving" in message:
        return "javascript_required"
    if "403" in message:
        return "http_403"
    if "429" in message:
        return "http_429"
    return "extraction_failed"


def verify_stream(audio_format):
    protocol = audio_format.get("protocol", "")
    is_hls = protocol.startswith("m3u8")
    headers = {} if is_hls else {"Range": "bytes=0-127"}
    request = Request(audio_format["url"], headers=headers)
    context = ssl.create_default_context(cafile=certifi.where())
    try:
        with urlopen(request, timeout=12, context=context) as response:
            prefix = response.read(128)
            content_type = response.headers.get_content_type()
            if is_hls:
                valid = prefix.startswith(b"#EXTM3U")
            else:
                valid = bool(prefix) and (content_type.startswith("audio/") or prefix[4:8] == b"ftyp")
            return {
                "result": "stream_verified" if valid else "unexpected_stream_response",
                "http": response.status,
                "format": audio_format.get("ext"),
                "protocol": protocol,
            }
    except HTTPError as error:
        return {"result": "stream_http_error", "http": error.code}
    except (URLError, TimeoutError):
        return {"result": "stream_unreachable"}


def probe(page_url):
    logger = ProbeLogger()
    with tempfile.TemporaryDirectory(prefix="hkotuner-resolver-") as scratch:
        options = {
            "quiet": True,
            "logger": logger,
            "cachedir": False,
            "noplaylist": True,
            "skip_download": True,
            "socket_timeout": 12,
            "retries": 0,
            "extractor_retries": 0,
            "js_runtimes": {},
            "remote_components": set(),
            # yt-dlp otherwise probes for FFmpeg even during metadata extraction.
            "ffmpeg_location": str(Path(scratch) / "missing-ffmpeg"),
        }
        try:
            with YoutubeDL(options) as resolver:
                result = resolver.extract_info(page_url, download=False)
        except DownloadError as error:
            return {"result": extraction_error(error, logger.warnings)}

    playable = [
        item for item in result.get("formats", [])
        if item.get("vcodec") == "none"
        and item.get("acodec", "none") != "none"
        and not item.get("has_drm")
        and item.get("url", "").startswith("https://")
        and (item.get("ext") in {"m4a", "mp3", "aac"} or item.get("protocol", "").startswith("m3u8"))
    ]
    if not playable:
        return {"result": "no_native_audio_format"}
    return verify_stream(playable[-1])


def main():
    sys.addaudithook(deny_external_process)
    os.environ["SSL_CERT_FILE"] = certifi.where()
    print(json.dumps({"platform": sys.platform, "python": sys.version.split()[0], "yt_dlp": __version__}), flush=True)
    success = True
    for service, page_url in TRACKS.items():
        try:
            result = probe(page_url)
        except ExternalProcessError:
            result = {"result": "external_process_requested"}
        except Exception as error:
            result = {"result": "runtime_error", "error_type": type(error).__name__}
        print(json.dumps({"service": service, **result}), flush=True)
        success = success and result["result"] == "stream_verified"
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
