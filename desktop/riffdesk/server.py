"""HTTP server: the sync API for the iPhone (token-protected) and the local web app (this computer only)."""

import hmac
import json
import mimetypes
import re
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import __version__, ai
from .ids import new_id

WEB = Path(__file__).parent / "web"
MAX_BODY = 1024 * 1024 * 1024  # 1 GB
TEXT_EXT = {".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".log", ".srt", ".vtt"}


def _primary_ip():
    """The address of the interface with the default route (your real Wi-Fi/Ethernet)."""
    for probe in ("192.168.255.255", "10.255.255.255", "8.8.8.8"):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((probe, 1))  # UDP connect sends no packet
            ip = s.getsockname()[0]
            s.close()
            if not ip.startswith(("127.", "0.")):
                return ip
        except OSError:
            continue
    return None


def _rank(ip: str) -> int:
    if ip.startswith("192.168."):
        return 0
    if ip.startswith("10."):
        return 1
    first, second = (int(x) for x in ip.split(".")[:2])
    if first == 100 and 64 <= second <= 127:  # Tailscale / CGNAT
        return 2
    if first == 172 and 16 <= second <= 31:  # often WSL / Hyper-V / Docker virtual adapters
        return 4
    return 3


def lan_addresses():
    """Addresses your phone can use, best first (the QR code uses the first)."""
    ips = set()
    primary = _primary_ip()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    ips = {ip for ip in ips if not ip.startswith(("127.", "169.254."))}
    ordered = sorted(ips - {primary}, key=lambda ip: (_rank(ip), ip))
    return ([primary] if primary else []) + ordered


def public_note(n: dict, light=False) -> dict:
    n = {k: v for k, v in n.items() if not k.startswith("_")}
    if light:
        n = dict(n)
        n["hasTranscript"] = bool((n.pop("transcript", None) or {}).get("segments"))
        n.pop("summaryStyle", None)
        n.pop("summaryInstructions", None)
        n["attachments"] = [{k: v for k, v in a.items() if k != "text"} for a in n.get("attachments") or []
                            if not a.get("deleted")]
    return n


class App:
    def __init__(self, store, config, worker):
        self.store, self.config, self.worker = store, config, worker

    def pairing(self, port):
        token = self.config.get("token")
        urls = [f"http://{ip}:{port}" for ip in lan_addresses()]
        links = [f"riffpocket://pair?url={urllib.parse.quote(u, safe='')}&token={token}" for u in urls]
        return {"urls": urls, "links": links, "token": token}


def make_handler(app: App):
    class Handler(BaseHTTPRequestHandler):
        server_version = f"RiffDesk/{__version__}"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quieter console
            if not self.path.startswith(("/ui/state", "/static")):
                super().log_message(fmt, *args)

        # ---- helpers -------------------------------------------------------
        def _send(self, code, body=b"", ctype="application/json", headers=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode("utf-8")
            elif isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _error(self, code, msg):
            self._send(code, {"error": msg})

        def _body(self) -> bytes:
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                raise ValueError("Upload too large")
            return self.rfile.read(n) if n else b""

        def _json(self):
            raw = self._body()
            return json.loads(raw.decode("utf-8")) if raw else {}

        def _send_file(self, path: Path, ctype=None):
            if not path or not path.exists():
                return self._error(404, "Not found")
            ctype = ctype or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            size = path.stat().st_size
            rng = self.headers.get("Range")
            if rng and (m := re.match(r"bytes=(\d*)-(\d*)", rng)):
                start = int(m.group(1) or 0)
                end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
                with path.open("rb") as f:
                    f.seek(start)
                    data = f.read(end - start + 1)
                return self._send(206, data, ctype, {"Content-Range": f"bytes {start}-{end}/{size}", "Accept-Ranges": "bytes"})
            self._send(200, path.read_bytes(), ctype, {"Accept-Ranges": "bytes"})

        def _authorized(self):
            got = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            return hmac.compare_digest(got.encode(), (app.config.get("token") or "").encode())

        def _is_local(self):
            return self.client_address[0] in ("127.0.0.1", "::1", "::ffff:127.0.0.1")

        def _route(self, method):
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path
            q = {k: v[-1] for k, v in urllib.parse.parse_qs(parsed.query).items()}
            try:
                if path.startswith("/api/v1/"):
                    if not self._authorized():
                        return self._error(401, "Pair this device first (wrong or missing token).")
                    return self._api(method, path[len("/api/v1/"):].strip("/").split("/"), q)
                if path.startswith("/ui/"):
                    if not self._is_local():
                        return self._error(403, "The Riff Desk web app is only available on this computer.")
                    return self._ui(method, path[len("/ui/"):].strip("/").split("/"), q)
                if method == "GET" and self._is_local():
                    if path in ("/", "/index.html"):
                        return self._send_file(WEB / "index.html", "text/html; charset=utf-8")
                    if path.startswith("/static/"):
                        f = (WEB / path[len("/static/"):]).resolve()
                        if WEB.resolve() in f.parents:
                            return self._send_file(f)
                return self._error(404, "Not found")
            except KeyError:
                return self._error(404, "Not found")
            except (ValueError, ai.AIError) as e:
                return self._error(400, str(e))
            except Exception as e:  # pragma: no cover
                return self._error(500, f"{type(e).__name__}: {e}")

        def do_GET(self): self._route("GET")
        def do_HEAD(self): self._route("GET")
        def do_PUT(self): self._route("PUT")
        def do_POST(self): self._route("POST")
        def do_PATCH(self): self._route("PATCH")
        def do_DELETE(self): self._route("DELETE")

        # ---- phone sync API --------------------------------------------------
        def _api(self, method, parts, q):
            store = app.store
            if parts == ["info"] and method == "GET":
                return self._send(200, {"name": socket.gethostname(), "version": __version__,
                                        "processing": app.worker.status != "Idle",
                                        "plaudConnected": bool(app.config.get("plaud"))})
            if parts == ["changes"] and method == "GET":
                ch = store.changes_since(int(q.get("since") or 0))
                ch["notes"] = [public_note(n) for n in ch["notes"]]
                return self._send(200, ch)
            if parts == ["settings"] and method == "PUT":
                body = self._json()
                settings = dict(app.config.get("settings") or {})
                settings.update({k: body[k] for k in ("defaultSummaryInstructions", "titleInstructions", "autoTranscribe",
                                                      "autoSummarize", "autoTitle") if k in body})
                app.config.set("settings", settings)
                app.worker.poke()
                return self._send(200, {"ok": True})
            if parts == ["plaud", "connect"] and method == "POST":
                body = self._json()
                if not body.get("userToken"):
                    raise ValueError("userToken is required")
                app.config.set("plaud", {"userToken": body["userToken"], "apiBase": body.get("apiBase"),
                                         "workspaceId": body.get("workspaceId")})
                app.worker.last_plaud_sync = 0
                app.worker.poke()
                return self._send(200, {"ok": True})
            if len(parts) == 2 and parts[0] == "folders" and method == "PUT":
                body = self._json()
                body["id"] = parts[1]
                return self._send(200, store.put_folder(body))
            if len(parts) >= 2 and parts[0] == "notes":
                nid = parts[1]
                if len(parts) == 2 and method == "PUT":
                    body = self._json()
                    body["id"] = nid
                    existing = store.get_note(nid)
                    if existing:
                        body["_failures"] = existing.get("_failures", 0)
                    return self._send(200, public_note(store.put_note(body, touch=False)))
                if len(parts) == 2 and method == "DELETE":
                    store.update_note(nid, deleted=True)
                    return self._send(200, {"ok": True})
                if len(parts) == 3 and parts[2] == "audio":
                    if method == "PUT":
                        if store.get_note(nid) is None:
                            raise KeyError(nid)
                        store.save_audio(nid, self._body(), q.get("name") or "audio.m4a")
                        app.worker.poke()
                        return self._send(200, {"ok": True})
                    return self._send_file(store.audio_path(nid))
                if len(parts) == 4 and parts[2] == "attachments":
                    if method == "PUT":
                        if store.get_note(nid) is None:
                            raise KeyError(nid)
                        store.save_attachment(nid, parts[3], self._body(), q.get("name"), q.get("type"))
                        return self._send(200, {"ok": True})
                    return self._send_file(store.attachment_path(nid, parts[3]), "application/octet-stream")
            return self._error(404, "Unknown endpoint")

        # ---- local web app API ----------------------------------------------
        def _ui(self, method, parts, q):
            store, cfg, worker = app.store, app.config, app.worker
            if parts == ["state"] and method == "GET":
                return self._send(200, {
                    "version": __version__,
                    "folders": store.folders(),
                    "notes": [public_note(n, light=True) for n in store.all_notes()],
                    "config": cfg.public(),
                    "worker": {"status": worker.status, "lastError": worker.last_error, "pending": len(worker.pending())},
                    "pairing": app.pairing(self.server.server_address[1]),
                })
            if parts == ["config"] and method == "PUT":
                body = self._json()
                for section in ("transcription", "chat"):
                    if section in body:
                        new = dict(body[section])
                        if str(new.get("apiKey", "")).startswith("•"):
                            new["apiKey"] = (cfg.get(section) or {}).get("apiKey", "")
                        cfg.set(section, new)
                if "plaudSyncMinutes" in body:
                    cfg.set("plaudSyncMinutes", float(body["plaudSyncMinutes"]))
                if "settings" in body:
                    s = dict(cfg.get("settings") or {})
                    s.update(body["settings"])
                    cfg.set("settings", s)
                worker.poke()
                return self._send(200, cfg.public())
            if parts == ["plaud", "sync"] and method == "POST":
                worker.last_plaud_sync = 0
                worker.poke()
                return self._send(200, {"ok": True})
            if parts == ["plaud", "disconnect"] and method == "POST":
                cfg.set("plaud", None)
                return self._send(200, {"ok": True})
            if parts == ["pairing", "reset"] and method == "POST":
                cfg.reset_token()
                return self._send(200, app.pairing(self.server.server_address[1]))
            if parts == ["process-all"] and method == "POST":
                for n in store.all_notes():
                    if n.get("_failures"):
                        n["_failures"] = 0
                        store.put_note(n, touch=False)
                worker.poke()
                return self._send(200, {"ok": True})
            if parts == ["chat"] and method == "POST":
                body = self._json()
                scope = body.get("scope") or "all"
                notes = store.all_notes()
                if scope == "unfiled":
                    notes = [n for n in notes if not n.get("folderId")]
                elif scope != "all":
                    notes = [n for n in notes if n.get("folderId") == scope]
                return self._send(200, {"answer": ai.ask(cfg.get("chat") or {}, body.get("question", ""), notes,
                                                         body.get("history"))})
            if parts == ["folders"] and method == "POST":
                return self._send(200, store.put_folder({"name": self._json().get("name")}))
            if len(parts) == 2 and parts[0] == "folders" and method == "DELETE":
                f = next((f for f in store.folders() if f["id"] == parts[1]), None)
                if f:
                    store.put_folder({**f, "deleted": True, "updatedAt": time.time()})
                    for n in store.all_notes():
                        if n.get("folderId") == parts[1]:
                            store.update_note(n["id"], folderId=None)
                return self._send(200, {"ok": True})
            if parts == ["import"] and method == "POST":
                name = q.get("name") or "audio.m4a"
                note = store.put_note({"id": new_id(), "title": Path(name).stem[:80] or "Recording", "source": "import",
                                       "folderId": q.get("folderId") or None})
                store.save_audio(note["id"], self._body(), name)
                worker.poke()
                return self._send(200, public_note(store.get_note(note["id"]), light=True))
            if len(parts) >= 2 and parts[0] == "notes":
                nid = parts[1]
                note = store.get_note(nid)
                if note is None:
                    raise KeyError(nid)
                if len(parts) == 2 and method == "GET":
                    return self._send(200, public_note(note))
                if len(parts) == 2 and method == "PATCH":
                    body = self._json()
                    changes = {}
                    if "title" in body:
                        changes.update(title=str(body["title"])[:120], titleLocked=True)
                    if "folderId" in body:
                        changes["folderId"] = body["folderId"] or None
                    if body.get("deleted"):
                        changes["deleted"] = True
                    return self._send(200, public_note(store.update_note(nid, **changes)))
                if len(parts) == 3 and parts[2] == "process" and method == "POST":
                    body = self._json()
                    if body.get("title"):
                        store.update_note(nid, titleLocked=False, _failures=0)
                    threading.Thread(target=worker.process_note, args=(nid,),
                                     kwargs={"force_summary": bool(body.get("summary")),
                                             "force_title": bool(body.get("title"))}, daemon=True).start()
                    return self._send(200, {"ok": True})
                if len(parts) == 3 and parts[2] == "ask" and method == "POST":
                    body = self._json()
                    return self._send(200, {"answer": ai.ask(cfg.get("chat") or {}, body.get("question", ""), [note],
                                                             body.get("history"))})
                if len(parts) == 3 and parts[2] == "audio":
                    return self._send_file(store.audio_path(nid))
                if len(parts) == 3 and parts[2] == "attachments" and method == "POST":
                    name = q.get("name") or "file"
                    data = self._body()
                    text = data.decode("utf-8", "replace")[:200_000] if Path(name).suffix.lower() in TEXT_EXT else None
                    store.save_attachment(nid, new_id(), data, name, mimetypes.guess_type(name)[0] or "public.data", text)
                    return self._send(200, public_note(store.get_note(nid)))
                if len(parts) == 4 and parts[2] == "attachments":
                    if method == "DELETE":
                        atts = [dict(a, deleted=True) if a["id"] == parts[3] else a for a in note["attachments"]]
                        return self._send(200, public_note(store.update_note(nid, attachments=atts)))
                    att = next((a for a in note["attachments"] if a["id"] == parts[3]), {})
                    return self._send_file(store.attachment_path(nid, parts[3]),
                                           mimetypes.guess_type(att.get("name", ""))[0])
            return self._error(404, "Unknown endpoint")

    return Handler


def serve(app: App, host="0.0.0.0", port=8765):
    httpd = ThreadingHTTPServer((host, port), make_handler(app))
    httpd.daemon_threads = True
    return httpd
