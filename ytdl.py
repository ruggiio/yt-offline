#!/usr/bin/env python3
"""Downloader YouTube per a-Shell (iPhone) — ma gira anche su PC/Termux.

Uso:
    python ytdl.py URL [URL ...]          # video, max 720p
    python ytdl.py -q 480 URL             # altezza massima 480p (meno spazio)
    python ytdl.py -a URL                 # solo audio (m4a)
    python ytdl.py -p URL                 # scarica l'intera playlist
    python ytdl.py                        # senza argomenti: chiede l'URL

I file finiscono in ~/Documents/YouTube (su iPhone: app File > a-Shell > YouTube).
"""
import argparse
import os
import sys

try:
    import yt_dlp
except ImportError:
    sys.exit("yt-dlp non installato. Esegui:  pip install yt-dlp")

DEST = os.path.join(os.path.expanduser("~"), "Documents", "YouTube")


def build_opts(quality: int, audio_only: bool, playlist: bool) -> dict:
    if audio_only:
        # m4a già pronto: non serve ffmpeg
        fmt = "bestaudio[ext=m4a]/bestaudio"
    else:
        # Un SOLO file mp4 con audio+video già uniti (progressive).
        # Su a-Shell yt-dlp non può lanciare ffmpeg come sottoprocesso,
        # quindi evitiamo i formati separati che richiedono il merge.
        fmt = (
            f"best[ext=mp4][height<={quality}]/"
            f"best[height<={quality}]/best"
        )
    return {
        "format": fmt,
        "outtmpl": os.path.join(DEST, "%(title).80s [%(id)s].%(ext)s"),
        "noplaylist": not playlist,
        "restrictfilenames": False,
        "continuedl": True,        # riprende i download interrotti
        "retries": 10,
        "fragment_retries": 10,
        "ignoreerrors": playlist,  # in playlist salta i video che falliscono
        "download_archive": os.path.join(DEST, ".archive.txt") if playlist else None,
        "quiet": False,
        "no_warnings": False,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Scarica video YouTube per vederli offline")
    ap.add_argument("urls", nargs="*", help="URL dei video")
    ap.add_argument("-q", "--quality", type=int, default=720, help="altezza max (default 720)")
    ap.add_argument("-a", "--audio", action="store_true", help="solo audio")
    ap.add_argument("-p", "--playlist", action="store_true", help="scarica tutta la playlist")
    args = ap.parse_args()

    urls = args.urls or [input("URL YouTube: ").strip()]
    urls = [u for u in urls if u]
    if not urls:
        return 1

    os.makedirs(DEST, exist_ok=True)
    opts = build_opts(args.quality, args.audio, args.playlist)

    failed = 0
    with yt_dlp.YoutubeDL(opts) as ydl:
        for url in urls:
            try:
                ydl.download([url])
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f"\n✗ Errore su {url}:\n  {e}\n")
    print(f"\nFatto. File in: {DEST}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
