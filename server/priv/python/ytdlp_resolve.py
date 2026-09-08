#!/usr/bin/env python3
"""Resolve a music page URL (SoundCloud short links, YouTube, …) via yt-dlp.

Used for local/agent smoke tests and as a reference CLI for the Elixir Music tool.

Usage:
  python3 server/priv/python/ytdlp_resolve.py "https://on.soundcloud.com/..."
  python3 server/priv/python/ytdlp_resolve.py --json "https://soundcloud.com/..."

Install:
  pip install -U yt-dlp
  # or: pip install -r server/priv/python/requirements.txt
"""

from __future__ import annotations

import argparse
import json
import sys


def resolve(url: str) -> dict:
    try:
        import yt_dlp
    except ImportError as exc:
        raise SystemExit(
            "yt-dlp is not installed. Run: pip install -U yt-dlp\n"
            f"Import error: {exc}"
        ) from exc

    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "format": "bestaudio/bestaudio*/best",
        "socket_timeout": 20,
        "retries": 3,
    }

    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)

    if not info:
        raise SystemExit("yt-dlp returned no info for that URL")

    # Playlist wrapper (rare for single track share links)
    if info.get("_type") == "playlist" and info.get("entries"):
        info = next((e for e in info["entries"] if e), info)

    webpage = info.get("webpage_url") or info.get("original_url") or url
    extractor = (info.get("extractor_key") or info.get("extractor") or "generic").lower()
    raw_id = str(info.get("id") or "")

    if "soundcloud" in extractor or "soundcloud.com" in webpage:
        source = "soundcloud"
        video_id = f"sc_{raw_id}" if raw_id else None
    elif "youtube" in extractor or "youtu" in webpage:
        source = "youtube"
        video_id = raw_id or None
    else:
        source = "web"
        video_id = f"x_{raw_id}" if raw_id else None

    duration = info.get("duration")
    if isinstance(duration, (int, float)):
        seconds = int(round(duration))
        mins, secs = divmod(seconds, 60)
        hours, mins = divmod(mins, 60)
        duration_str = (
            f"{hours}:{mins:02d}:{secs:02d}" if hours else f"{mins}:{secs:02d}"
        )
    else:
        duration_str = None
        seconds = None

    thumbs = info.get("thumbnails") or []
    cover = info.get("thumbnail")
    if not cover and thumbs:
        cover = thumbs[-1].get("url")

    return {
        "ok": True,
        "source": source,
        "video_id": video_id,
        "title": info.get("title") or info.get("track"),
        "artist": info.get("uploader")
        or info.get("channel")
        or info.get("creator")
        or (info.get("artists") or [None])[0],
        "duration": duration_str,
        "duration_seconds": seconds,
        "cover": cover,
        "webpage_url": webpage,
        "stream_url": info.get("url"),
        "extractor": extractor,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Resolve music URL with yt-dlp")
    parser.add_argument("url", help="SoundCloud / YouTube / other yt-dlp page URL")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON (default)",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print human summary",
    )
    args = parser.parse_args(argv)

    result = resolve(args.url.strip())

    if args.pretty:
        print(f"source:   {result['source']}")
        print(f"title:    {result['title']}")
        print(f"artist:   {result['artist']}")
        print(f"id:       {result['video_id']}")
        print(f"duration: {result['duration']}")
        print(f"page:     {result['webpage_url']}")
        print(f"stream:   {'yes' if result.get('stream_url') else 'no'}")
        return 0

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
