import json
import ssl
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import certifi
from yt_dlp.version import __version__

from hk_audio_resolver import ResolverError, resolve, search_soundcloud


TRACKS = {
    "youtube_music": "https://music.youtube.com/watch?v=KLbkyunVsnY",
    "soundcloud": "https://soundcloud.com/forss/flickermood",
}


class ExternalProcessError(RuntimeError):
    pass


def deny_external_process(event, _args):
    if event in {"subprocess.Popen", "os.system", "os.exec", "os.spawn", "os.posix_spawn", "os.fork"}:
        raise ExternalProcessError("External processes are unavailable")


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
                "format": audio_format.get("format"),
                "protocol": protocol,
            }
    except HTTPError as error:
        return {"result": "stream_http_error", "http": error.code}
    except (URLError, TimeoutError):
        return {"result": "stream_unreachable"}


def main():
    sys.addaudithook(deny_external_process)
    print(json.dumps({"platform": sys.platform, "python": sys.version.split()[0], "yt_dlp": __version__}), flush=True)
    success = True
    for service, page_url in TRACKS.items():
        try:
            if service == "soundcloud":
                results = search_soundcloud("Forss Flickermood")
                if not any(track["url"] == page_url for track in results):
                    raise ResolverError("search_did_not_find_track")
            result = verify_stream(resolve(page_url))
        except ResolverError as error:
            result = {"result": str(error)}
        except ExternalProcessError:
            result = {"result": "external_process_requested"}
        except Exception as error:
            result = {"result": "runtime_error", "error_type": type(error).__name__}
        print(json.dumps({"service": service, **result}), flush=True)
        success = success and result["result"] == "stream_verified"
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
