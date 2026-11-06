import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from riffdesk import ai  # noqa: E402
from riffdesk.config import Config  # noqa: E402
from riffdesk.ids import note_id_for_plaud  # noqa: E402
from riffdesk.server import App, serve  # noqa: E402
from riffdesk.store import Store  # noqa: E402
from riffdesk.worker import Worker  # noqa: E402


class IdsTest(unittest.TestCase):
    def test_matches_swift_vector(self):
        # Same vector as RiffCore DeskTests.testNoteIdIsStableAndMatchesDesktop
        self.assertEqual(note_id_for_plaud("f_abc123"), "39126D8B-41E6-57D6-B88A-2CB31BE9809F")


class AITextTest(unittest.TestCase):
    def test_title_cleanup_and_placeholders(self):
        self.assertEqual(ai.clean_title('"Team Meeting: Q4 Roadmap."'), "Team Meeting Q4 Roadmap")
        self.assertEqual(ai.clean_title("Title: **Sprint Planning; Velocity**\nmore"), "Sprint Planning Velocity")
        self.assertLessEqual(len(ai.clean_title("Roadmap " * 20)), 60)
        for t in ["2025-11-05 14:30:12", "Recording", "Phone recording Nov 5", ""]:
            self.assertTrue(ai.is_placeholder_title(t), t)
        self.assertFalse(ai.is_placeholder_title("Q3 Budget 2025 Review"))

    def test_thinking_stripped(self):
        self.assertEqual(ai.strip_thinking("<think>hmm</think>\nAnswer"), "Answer")

    def test_library_context_finds_relevant_note_and_attachment(self):
        filler = {"segments": [{"start": i, "end": i + 1, "text": f"filler words number {i} here"} for i in range(300)]}
        notes = [{"title": f"Meeting {i}", "createdAt": i, "transcript": filler} for i in range(10)]
        notes.append({"title": "Vendor call", "createdAt": 50, "transcript": None,
                      "attachments": [{"name": "quote.pdf", "text": "Total price 12,400 dollars for the zebra licenses"}]})
        ctx = ai.library_context("What is the zebra price?", notes, 2_000)
        self.assertIn("12,400", ctx)
        self.assertIn("### Vendor call", ctx)
        self.assertLessEqual(len(ctx), 2_200)


class FakeAI:
    """Replaces network calls in ai.py."""
    def __init__(self):
        self.calls = []

    def complete(self, cfg, messages, max_tokens=1200):
        self.calls.append(messages)
        system = messages[0]["content"]
        if "title for a recorded note" in system:
            return "Title: Pricing Review: Q4 Plan."
        if "answer questions" in system.lower():
            return "ANSWER from " + messages[1]["content"][:40]
        return "## Summary\n- Agreed on Q4 pricing [00:00:01]"

    def transcribe(self, cfg, path):
        return {"language": "en", "segments": [{"start": 1, "end": 3, "text": "We agreed on Q4 pricing", "speaker": None}]}


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.config = Config(root)
        cls.config.set("transcription", {"kind": "openai", "model": "whisper-1"})
        cls.store = Store(root)
        cls.worker = Worker(cls.store, cls.config)
        cls.fake = FakeAI()
        cls._orig = (ai.complete, ai.transcribe)
        ai.complete, ai.transcribe = cls.fake.complete, cls.fake.transcribe
        cls.httpd = serve(App(cls.store, cls.config, cls.worker), "127.0.0.1", 0)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        ai.complete, ai.transcribe = cls._orig
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.store.db.close()
        cls.tmp.cleanup()

    def req(self, method, path, body=None, token=True, raw=False, headers=None):
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        h = dict(headers or {})
        if token:
            h["Authorization"] = "Bearer " + self.config.get("token")
        if data is not None and not isinstance(body, bytes):
            h["Content-Type"] = "application/json"
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method, headers=h)
        with urllib.request.urlopen(r, timeout=10) as resp:
            payload = resp.read()
            return (resp.status, payload) if raw else json.loads(payload)

    def test_01_requires_token(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.req("GET", "/api/v1/info", token=False)
        self.assertEqual(cm.exception.code, 401)
        self.assertIn("version", self.req("GET", "/api/v1/info"))

    def test_02_phone_sync_round_trip(self):
        start = self.req("GET", "/api/v1/changes?since=0")["cursor"]
        note = {"id": "N-PHONE-1", "title": "2025-11-05 14:30:12", "titleLocked": False, "createdAt": 1762300000.0,
                "updatedAt": 1762300000.5, "duration": 60, "source": "mic", "hasAudio": False, "attachments": [],
                "deleted": False, "summaryInstructions": "Summarize briefly."}
        out = self.req("PUT", "/api/v1/notes/N-PHONE-1", note)
        self.assertEqual(out["updatedAt"], 1762300000.5)        # phone's timestamp kept
        self.assertFalse(out["hasAudio"])
        self.req("PUT", "/api/v1/notes/N-PHONE-1/audio?name=rec.m4a", b"\x00\x00\x00\x20ftypM4A fake-audio-bytes")
        ch = self.req("GET", f"/api/v1/changes?since={start}")
        got = next(n for n in ch["notes"] if n["id"] == "N-PHONE-1")
        self.assertTrue(got["hasAudio"])
        self.assertGreater(ch["cursor"], start)
        status, part = self.req("GET", "/api/v1/notes/N-PHONE-1/audio", raw=True, headers={"Range": "bytes=4-7"})
        self.assertEqual((status, part), (206, b"ftyp"))
        self.req("PUT", "/api/v1/folders/F1", {"id": "F1", "name": "Work", "updatedAt": 1.0, "deleted": False})
        self.assertTrue(any(f["id"] == "F1" for f in self.req("GET", f"/api/v1/changes?since={start}")["folders"]))

    def test_03_worker_processes_and_names(self):
        self.worker.process_note("N-PHONE-1")
        n = self.store.get_note("N-PHONE-1")
        self.assertEqual(n["transcript"]["segments"][0]["text"], "We agreed on Q4 pricing")
        self.assertIn("Q4 pricing", n["summary"])
        self.assertEqual(n["title"], "Pricing Review Q4 Plan")
        # The note's own style instructions were used for the summary.
        self.assertTrue(any(m[0]["content"] == "Summarize briefly." for m in self.fake.calls))

    def test_04_locked_title_is_kept(self):
        self.req("PATCH", "/ui/notes/N-PHONE-1", {"title": "My Own Name"}, token=False)
        self.worker.process_note("N-PHONE-1", force_summary=True)
        n = self.store.get_note("N-PHONE-1")
        self.assertEqual(n["title"], "My Own Name")
        self.assertTrue(n["titleLocked"])

    def test_05_ui_state_chat_and_attachments(self):
        state = self.req("GET", "/ui/state", token=False)
        self.assertTrue(any(n["id"] == "N-PHONE-1" for n in state["notes"]))
        self.assertNotIn("token", state["config"])          # never exposed to the page config
        self.assertTrue(state["pairing"]["links"] or state["pairing"]["urls"] == [])
        note = self.req("POST", "/ui/notes/N-PHONE-1/attachments?name=agenda.md", b"# Agenda\nZebra launch on March 3", token=False)
        att = next(a for a in note["attachments"] if a["name"] == "agenda.md")
        self.assertIn("March 3", att["text"])
        ans = self.req("POST", "/ui/chat", {"question": "When is the zebra launch?", "scope": "all"}, token=False)
        self.assertTrue(ans["answer"].startswith("ANSWER"))

    def test_06_plaud_connect_and_settings(self):
        self.req("PUT", "/api/v1/settings", {"defaultSummaryInstructions": "X", "titleInstructions": "Y",
                                              "autoTranscribe": True, "autoSummarize": False, "autoTitle": True})
        self.assertFalse(self.config.get("settings")["autoSummarize"])
        self.req("POST", "/api/v1/plaud/connect", {"userToken": "eyJ.x.y", "apiBase": "https://api.plaud.ai"})
        self.assertEqual(self.config.get("plaud")["apiBase"], "https://api.plaud.ai")
        self.config.set("plaud", None)

    def test_07_static_web_app(self):
        status, html = self.req("GET", "/", token=False, raw=True)
        self.assertEqual(status, 200)
        self.assertIn(b"Riff Desk", html)
        status, _ = self.req("GET", "/static/app.js", token=False, raw=True)
        self.assertEqual(status, 200)
        with self.assertRaises(urllib.error.HTTPError):
            self.req("GET", "/static/../server.py", token=False, raw=True)


if __name__ == "__main__":
    unittest.main()
