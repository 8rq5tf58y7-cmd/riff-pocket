"""Notes, folders and files on disk (SQLite + a files folder). Every change bumps a sequence
number so the phone can ask for "changes since N"."""

import json
import os
import re
import sqlite3
import threading
import time
from pathlib import Path

from .ids import new_id

NOTE_FIELDS_DEFAULTS = {
    "title": "Recording",
    "titleLocked": False,
    "createdAt": 0.0,
    "updatedAt": 0.0,
    "duration": 0.0,
    "source": "desk",
    "plaudId": None,
    "folderId": None,
    "transcript": None,
    "transcriptSource": None,
    "summary": None,
    "summarySource": None,
    "summaryStyle": None,
    "summaryInstructions": None,
    "audioName": None,
    "hasAudio": False,
    "attachments": [],
    "deleted": False,
    "_failures": 0,  # desk-only: processing attempts that failed (the phone ignores it)
}

SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def safe_name(name: str, fallback: str = "file") -> str:
    base = SAFE_NAME.sub("_", os.path.basename(name or ""))[:120].strip("._")
    return base or fallback


class Store:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.files = self.root / "files"
        self.files.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(self.root / "riffdesk.db"), check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, doc TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, doc TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS notes_seq ON notes(seq);
            CREATE INDEX IF NOT EXISTS folders_seq ON folders(seq);
            """
        )
        self.db.commit()

    # ---- sequence -------------------------------------------------------
    def _next_seq(self) -> int:
        cur = self.db.execute("SELECT value FROM meta WHERE key='seq'").fetchone()
        n = int(cur[0]) + 1 if cur else 1
        self.db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('seq', ?)", (str(n),))
        return n

    def cursor(self) -> int:
        with self.lock:
            cur = self.db.execute("SELECT value FROM meta WHERE key='seq'").fetchone()
            return int(cur[0]) if cur else 0

    def get_meta(self, key, default=None):
        with self.lock:
            row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
            return json.loads(row[0]) if row else default

    def set_meta(self, key, value):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", (key, json.dumps(value)))
            self.db.commit()

    # ---- notes ----------------------------------------------------------
    @staticmethod
    def normalize(doc: dict) -> dict:
        out = dict(NOTE_FIELDS_DEFAULTS)
        out.update({k: v for k, v in doc.items() if k in NOTE_FIELDS_DEFAULTS or k == "id"})
        out["attachments"] = list(out.get("attachments") or [])
        return out

    def get_note(self, note_id: str):
        with self.lock:
            row = self.db.execute("SELECT doc FROM notes WHERE id=?", (note_id,)).fetchone()
            return self.normalize(json.loads(row[0])) if row else None

    def find_by_plaud(self, plaud_id: str):
        for n in self.all_notes(include_deleted=True):
            if n.get("plaudId") == plaud_id:
                return n
        return None

    def all_notes(self, include_deleted=False):
        with self.lock:
            rows = self.db.execute("SELECT doc FROM notes").fetchall()
        notes = [self.normalize(json.loads(r[0])) for r in rows]
        if not include_deleted:
            notes = [n for n in notes if not n["deleted"]]
        return sorted(notes, key=lambda n: n["createdAt"], reverse=True)

    def put_note(self, doc: dict, touch: bool = True) -> dict:
        """Insert or replace a note. Keeps server-side truth for hasAudio."""
        with self.lock:
            note = self.normalize(doc)
            if not note.get("id"):
                note["id"] = new_id()
            existing = self.get_note(note["id"])
            note["hasAudio"] = self.audio_path(note["id"], existing or note) is not None
            if touch:
                note["updatedAt"] = max(time.time(), float(note.get("updatedAt") or 0))
            if not note["createdAt"]:
                note["createdAt"] = existing["createdAt"] if existing else time.time()
            self.db.execute(
                "INSERT OR REPLACE INTO notes(id, seq, doc) VALUES(?, ?, ?)",
                (note["id"], self._next_seq(), json.dumps(note)),
            )
            self.db.commit()
            return note

    def update_note(self, note_id: str, **changes) -> dict:
        with self.lock:
            note = self.get_note(note_id)
            if note is None:
                raise KeyError(note_id)
            note.update(changes)
            return self.put_note(note)

    def changes_since(self, seq: int):
        with self.lock:
            notes = [self.normalize(json.loads(r[0])) for r in
                     self.db.execute("SELECT doc FROM notes WHERE seq > ? ORDER BY seq", (seq,)).fetchall()]
            folders = [json.loads(r[0]) for r in
                       self.db.execute("SELECT doc FROM folders WHERE seq > ? ORDER BY seq", (seq,)).fetchall()]
            return {"cursor": self.cursor(), "notes": notes, "folders": folders}

    # ---- folders --------------------------------------------------------
    def put_folder(self, doc: dict) -> dict:
        with self.lock:
            folder = {
                "id": doc.get("id") or new_id(),
                "name": (doc.get("name") or "Folder").strip()[:80],
                "updatedAt": float(doc.get("updatedAt") or time.time()),
                "deleted": bool(doc.get("deleted", False)),
            }
            self.db.execute("INSERT OR REPLACE INTO folders(id, seq, doc) VALUES(?, ?, ?)",
                            (folder["id"], self._next_seq(), json.dumps(folder)))
            self.db.commit()
            return folder

    def folders(self):
        with self.lock:
            rows = self.db.execute("SELECT doc FROM folders").fetchall()
        return sorted([f for f in (json.loads(r[0]) for r in rows) if not f.get("deleted")],
                      key=lambda f: f["name"].lower())

    # ---- files ----------------------------------------------------------
    def note_dir(self, note_id: str) -> Path:
        d = self.files / safe_name(note_id, "note")
        d.mkdir(parents=True, exist_ok=True)
        return d

    def audio_path(self, note_id: str, note: dict = None):
        d = self.files / safe_name(note_id, "note")
        if not d.exists():
            return None
        for p in d.iterdir():
            if p.name.startswith("audio."):
                return p
        return None

    def save_audio(self, note_id: str, data: bytes, name: str) -> Path:
        ext = re.sub(r"[^a-z0-9]", "", os.path.splitext(name or "")[1].lower())[:5] or "m4a"
        d = self.note_dir(note_id)
        for p in d.iterdir():
            if p.name.startswith("audio."):
                p.unlink()
        path = d / f"audio.{ext}"
        path.write_bytes(data)
        note = self.get_note(note_id)
        if note is not None:
            note["audioName"] = note.get("audioName") or safe_name(name, "audio" + ext)
            self.put_note(note)
        return path

    def attachment_path(self, note_id: str, att_id: str) -> Path:
        return self.note_dir(note_id) / ("att-" + safe_name(att_id, "x"))

    def save_attachment(self, note_id: str, att_id: str, data: bytes, name: str, content_type: str, text=None):
        self.attachment_path(note_id, att_id).write_bytes(data)
        note = self.get_note(note_id)
        if note is None:
            return
        atts = [a for a in note["attachments"] if a.get("id") != att_id]
        prior = next((a for a in note["attachments"] if a.get("id") == att_id), {})
        atts.append({"id": att_id, "name": name or prior.get("name") or "file", "contentType": content_type or "public.data",
                     "size": len(data), "text": text if text is not None else prior.get("text"), "deleted": False})
        note["attachments"] = sorted(atts, key=lambda a: a["id"])  # same order as the phone sends
        self.put_note(note)
