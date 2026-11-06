"""Background work on the desktop: sync Plaud, then transcribe → summarize → name new notes.

This is what lets notes get processed while the phone is asleep: the PC does the work,
and the iPhone just pulls the results (a few KB) on its next background refresh."""

import threading
import time
import traceback

from . import ai
from .ids import note_id_for_plaud
from .plaud import PlaudClient, PlaudError


class Worker:
    def __init__(self, store, config):
        self.store = store
        self.config = config  # Config object (dict-like, saves itself)
        self.wake = threading.Event()
        self.status = "Idle"
        self.last_error = None
        self.last_plaud_sync = 0.0
        self._stop = False
        self._thread = threading.Thread(target=self._run, name="riffdesk-worker", daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._stop = True
        self.wake.set()

    def poke(self):
        self.wake.set()

    # ---- loop -----------------------------------------------------------
    def _run(self):
        while not self._stop:
            try:
                minutes = float(self.config.get("plaudSyncMinutes", 15) or 0)
                if self.config.get("plaud") and minutes > 0 and time.time() - self.last_plaud_sync > minutes * 60:
                    self.sync_plaud()
                self.process_pending()
                self.status = "Idle"
            except Exception as e:  # keep the worker alive
                self.last_error = str(e)
                self.status = "Idle"
                traceback.print_exc()
            self.wake.wait(timeout=30)
            self.wake.clear()

    # ---- Plaud -----------------------------------------------------------
    def sync_plaud(self):
        creds = self.config.get("plaud")
        if not creds:
            return 0
        self.status = "Checking Plaud"
        self.last_plaud_sync = time.time()
        client = PlaudClient(creds["userToken"], creds.get("apiBase"), creds.get("workspaceId"))
        added = 0
        try:
            for rec in reversed(client.list_recordings()):  # oldest first
                nid = note_id_for_plaud(rec["id"])
                existing = self.store.get_note(nid)
                if existing and (existing.get("hasAudio") or existing.get("deleted")):
                    continue
                self.status = f"Downloading {rec.get('filename') or 'recording'}"
                data, ext = client.download_audio(rec["id"])
                note = existing or {"id": nid, "title": rec.get("filename") or "Recording", "source": "plaud",
                                    "plaudId": rec["id"], "createdAt": (rec.get("start_ms") or 0) / 1000 or time.time(),
                                    "duration": (rec.get("duration_ms") or 0) / 1000}
                self.store.put_note(note)
                self.store.save_audio(nid, data, f"plaud-{rec['id']}{ext}")
                if self.config.get("settings", {}).get("preferPlaudContent", True) and rec.get("is_trans") is not False:
                    try:
                        transcript, summary = client.content(rec["id"])
                        changes = {}
                        if transcript and not note.get("transcript"):
                            changes.update(transcript=transcript, transcriptSource="plaud")
                        if summary and not note.get("summary"):
                            changes.update(summary=summary, summarySource="plaud")
                        if changes:
                            self.store.update_note(nid, **changes)
                    except PlaudError:
                        pass
                added += 1
        except PlaudError as e:
            self.last_error = str(e)
        return added

    # ---- processing --------------------------------------------------------
    def _settings(self):
        s = {"autoTranscribe": True, "autoSummarize": True, "autoTitle": True,
             "defaultSummaryInstructions": ai.DEFAULT_SUMMARY_INSTRUCTIONS, "titleInstructions": ai.TITLE_INSTRUCTIONS}
        s.update({k: v for k, v in (self.config.get("settings") or {}).items() if v is not None})
        return s

    def pending(self):
        s = self._settings()
        out = []
        for n in self.store.all_notes():
            if n.get("_failures", 0) >= 2:
                continue
            needs_t = s["autoTranscribe"] and not n.get("transcript") and n.get("hasAudio")
            needs_s = s["autoSummarize"] and n.get("transcript") and not n.get("summary")
            if needs_t or needs_s:
                out.append(n)
        return out

    def process_pending(self):
        for note in self.pending():
            if self._stop:
                return
            self.process_note(note["id"])

    def process_note(self, note_id, force_summary=False, force_title=False):
        s = self._settings()
        note = self.store.get_note(note_id)
        if note is None:
            return
        try:
            if not note.get("transcript") and note.get("hasAudio"):
                tcfg = self.config.get("transcription") or {}
                if tcfg.get("kind", "none") == "none":
                    raise ai.AIError("Set up transcription in Riff Desk settings.")
                self.status = f"Transcribing “{note['title']}”"
                transcript = ai.transcribe(tcfg, self.store.audio_path(note_id))
                note = self.store.update_note(note_id, transcript=transcript,
                                              transcriptSource=f"Riff Desk · {tcfg.get('model') or tcfg.get('kind')}")
            chat = self.config.get("chat") or {}
            summarized = False
            if note.get("transcript") and (force_summary or not note.get("summary")):
                self.status = f"Summarizing “{note['title']}”"
                summary = ai.summarize(chat, note["transcript"],
                                       note.get("summaryInstructions") or s["defaultSummaryInstructions"])
                note = self.store.update_note(note_id, summary=summary,
                                              summarySource=f"Riff Desk · {chat.get('model') or chat.get('kind')}")
                summarized = True
            if s["autoTitle"] and not note.get("titleLocked") and (summarized or force_title
                                                                     or ai.is_placeholder_title(note.get("title"))):
                self.status = f"Naming “{note['title']}”"
                title = ai.make_title(chat, note.get("summary"), note.get("transcript"), s.get("titleInstructions"))
                if title and title != note.get("title"):
                    self.store.update_note(note_id, title=title)
            self.store.update_note(note_id, _failures=0) if note.get("_failures") else None
        except Exception as e:
            self.last_error = f"“{note.get('title')}”: {e}"
            raw = self.store.get_note(note_id) or {}
            raw["_failures"] = int(raw.get("_failures", 0)) + 1
            self.store.put_note(raw, touch=False)
