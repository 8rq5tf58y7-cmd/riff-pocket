"""Riff Desk settings, saved as JSON in the data folder (keys stay on this computer)."""

import json
import secrets
import threading
from pathlib import Path

DEFAULTS = {
    "port": 8765,
    "token": None,  # pairing token the iPhone uses
    "plaud": None,  # {userToken, apiBase, workspaceId} — sent from the iPhone
    "plaudSyncMinutes": 15,
    "transcription": {"kind": "none", "baseURL": "https://api.openai.com/v1", "model": "whisper-1", "apiKey": ""},
    "chat": {"kind": "ollama", "baseURL": "http://localhost:11434", "model": "llama3.2", "apiKey": ""},
    "settings": {},  # pushed from the iPhone: auto toggles, summary/title instructions
}


class Config:
    def __init__(self, root: Path):
        self.path = Path(root) / "config.json"
        self.lock = threading.RLock()
        self.data = json.loads(json.dumps(DEFAULTS))
        if self.path.exists():
            try:
                self.data.update(json.loads(self.path.read_text("utf-8")))
            except ValueError:
                pass
        if not self.data.get("token"):
            self.data["token"] = secrets.token_urlsafe(24)
        self.save()

    def get(self, key, default=None):
        with self.lock:
            return self.data.get(key, default)

    def set(self, key, value):
        with self.lock:
            self.data[key] = value
            self.save()

    def update(self, **kv):
        with self.lock:
            self.data.update(kv)
            self.save()

    def reset_token(self):
        self.set("token", secrets.token_urlsafe(24))

    def save(self):
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data, indent=2), "utf-8")
            tmp.replace(self.path)

    def public(self):
        """Settings for the web UI with API keys masked."""
        with self.lock:
            out = json.loads(json.dumps(self.data))
        for section in ("transcription", "chat"):
            key = (out.get(section) or {}).get("apiKey")
            out[section]["apiKey"] = ("•" * 8 + key[-4:]) if key else ""
        out["plaudConnected"] = bool(out.pop("plaud", None))
        out.pop("token", None)
        return out
