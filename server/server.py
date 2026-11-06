#!/usr/bin/env python3
"""Server per YT Offline: scarica con yt-dlp e serve i file all'app sull'iPhone.

    python3 server.py [--port 8790] [--dir ~/YT-Offline]

Pagina web su http://IP-DEL-PC:8790 (utile anche da Safari). Solo rete locale, senza password:
non lasciarlo acceso su Wi-Fi pubbliche.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

VIDEO_EXT = {".mp4", ".m4v", ".mov", ".m4a", ".mp3"}
JOBS: dict[str, dict] = {}
LOCK = threading.Lock()
DIR = Path.home() / "YT-Offline"
_VENV = Path(__file__).resolve().parent.parent / ".venv" / "bin" / "yt-dlp"
YTDLP = str(_VENV) if _VENV.exists() else (shutil.which("yt-dlp") or "yt-dlp")


def fmt_selector(quality: int, audio: bool) -> list[str]:
    if audio:
        return ["-f", "bestaudio[ext=m4a]/bestaudio", "-x", "--audio-format", "m4a"]
    # H.264 + AAC dentro un mp4: l'unico che l'iPhone riproduce sempre.
    sel = (
        f"bv*[height<={quality}][vcodec^=avc1]+ba[ext=m4a]/"
        f"b[height<={quality}][ext=mp4]/b[height<={quality}]"
    )
    return ["-f", sel, "--merge-output-format", "mp4"]


def run_job(job_id: str) -> None:
    job = JOBS[job_id]
    cmd = [
        YTDLP, "--newline", "--no-colors", "--windows-filenames",
        *(["--yes-playlist"] if job["playlist"] else ["--no-playlist"]),
        *fmt_selector(job["quality"], job["audio"]),
        "-o", str(DIR / "%(title).90B [%(id)s].%(ext)s"),
        "--", job["url"],
    ]
    job["state"] = "download"
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        tail: list[str] = []
        for line in p.stdout:  # type: ignore[union-attr]
            line = line.rstrip()
            tail = (tail + [line])[-6:]
            m = re.search(r"\[download\]\s+([\d.]+)%", line)
            if m:
                job["progress"] = float(m.group(1)) / 100
            m = re.search(r"\[download\] Destination: (.+)$", line) or re.search(
                r'\[Merger\] Merging formats into "(.+)"', line)
            if m:
                job["title"] = Path(m.group(1)).stem
        p.wait()
        if p.returncode == 0:
            job["state"], job["progress"] = "done", 1.0
        else:
            job["state"], job["error"] = "error", " | ".join(tail[-3:])
    except Exception as e:  # noqa: BLE001
        job["state"], job["error"] = "error", str(e)


def list_videos() -> list[dict]:
    out = []
    for f in sorted(DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if f.suffix.lower() in VIDEO_EXT and not f.name.endswith((".part", ".ytdl")):
            out.append({"name": f.name, "size": f.stat().st_size})
    return out


def state() -> dict:
    with LOCK:
        jobs = sorted(JOBS.values(), key=lambda j: j["t"], reverse=True)[:20]
    return {"videos": list_videos(), "jobs": jobs}


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>YT Offline</title>
<style>body{font:16px system-ui;max-width:640px;margin:1rem auto;padding:0 1rem}
input,select,button{font:inherit;padding:.5rem;margin:.2rem 0}input[type=text]{width:100%;box-sizing:border-box}
li{margin:.4rem 0}progress{width:100%}.e{color:#c00}small{color:#666}</style>
<h2>YT Offline</h2>
<input id=u type=text placeholder="Link YouTube (video o playlist)">
<select id=q><option>480<option selected>720<option>1080</select>
<label><input id=a type=checkbox> solo audio</label>
<label><input id=p type=checkbox> playlist</label>
<button onclick=add()>Scarica sul PC</button>
<h3>Coda</h3><ul id=j></ul><h3>File sul PC</h3><ul id=v></ul>
<script>
async function add(){const u=document.getElementById('u');if(!u.value)return;
await fetch('/api/add',{method:'POST',body:JSON.stringify({url:u.value,quality:+q.value,audio:a.checked,playlist:p.checked})});u.value='';tick()}
async function tick(){const s=await (await fetch('/api/state')).json();
j.innerHTML=s.jobs.map(x=>`<li>${x.title||x.url}<br><progress value=${x.progress||0}></progress> <small>${x.state}</small>${x.error?`<div class=e>${x.error}</div>`:''}</li>`).join('');
v.innerHTML=s.videos.map(x=>`<li><a href="/files/${encodeURIComponent(x.name)}">${x.name}</a> <small>${(x.size/1e6).toFixed(0)} MB</small></li>`).join('')}
tick();setInterval(tick,2000)
</script>"""


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):  # meno rumore
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/state":
            self._json(state())
        elif path.startswith("/files/"):
            name = Path(unquote(path[len("/files/"):])).name  # niente "../"
            f = DIR / name
            if not f.is_file():
                return self.send_error(404)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(f.stat().st_size))
            self.end_headers()
            with open(f, "rb") as fh:
                shutil.copyfileobj(fh, self.wfile, 1 << 20)
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        if path not in ("/api/add", "/api/delete"):
            return self.send_error(404)
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n))
            if path == "/api/delete":
                f = DIR / Path(str(req["name"])).name  # solo file dentro la cartella
                if f.suffix.lower() not in VIDEO_EXT or not f.is_file():
                    raise ValueError("file non trovato")
                f.unlink()
                return self._json({"ok": True})
            url = str(req["url"]).strip()
            if not re.match(r"^https?://", url):
                raise ValueError("serve un link http(s)")
            job_id = uuid.uuid4().hex[:8]
            job = {"id": job_id, "url": url, "title": None, "state": "coda", "progress": 0.0,
                   "error": None, "t": time.time(), "quality": int(req.get("quality", 720)),
                   "audio": bool(req.get("audio")), "playlist": bool(req.get("playlist"))}
            with LOCK:
                JOBS[job_id] = job
            threading.Thread(target=run_job, args=(job_id,), daemon=True).start()
            self._json({"ok": True, "id": job_id})
        except Exception as e:  # noqa: BLE001
            self._json({"ok": False, "error": str(e)}, 400)


def main() -> None:
    global DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--dir", type=Path, default=DIR)
    args = ap.parse_args()
    DIR = args.dir.expanduser()
    DIR.mkdir(parents=True, exist_ok=True)
    print(f"Cartella: {DIR}\nPagina:   http://0.0.0.0:{args.port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
