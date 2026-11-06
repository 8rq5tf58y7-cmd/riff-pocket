"""Plaud cloud client for Riff Desk — port of RiffCore's PlaudClient, itself ported from Riffado
(src/lib/plaud, incl. Plaud 4.0 support from riffado/riffado#328). AGPL-3.0."""

import gzip
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
MIGRATED = -1800907
VALID_HOST = re.compile(r"^https://([a-z0-9-]+\.)*plaud\.(ai|cn)$")


class PlaudError(Exception):
    pass


def is_migrated(body) -> bool:
    if not isinstance(body, dict):
        return False
    return body.get("status") == MIGRATED or "migrated to 4.0" in str(body.get("msg", "")).lower()


class PlaudClient:
    def __init__(self, user_token: str, api_base: str, workspace_id: str = None):
        api_base = (api_base or "https://api.plaud.ai").rstrip("/")
        if not VALID_HOST.match(api_base):
            raise PlaudError(f"Not a Plaud API host: {api_base}")
        self.user_token = user_token
        self.api_base = api_base
        self.workspace_id = workspace_id
        self.workspace_token = None
        self.use_v4 = False
        self._detail_cache = {}

    # ---- low level -----------------------------------------------------
    def _call(self, path, bearer, method="GET", body=None, attempt=0):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.api_base + "/" + path.lstrip("/"), data=data, method=method, headers={
            "Authorization": f"Bearer {bearer}", "Content-Type": "application/json", "User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise PlaudError("Plaud rejected the token — reconnect from the iPhone app.") from None
            if (e.code == 429 or e.code >= 500) and attempt < 3:
                time.sleep(2 ** attempt)
                return self._call(path, bearer, method, body, attempt + 1)
            raise PlaudError(f"Plaud HTTP {e.code}") from None
        except urllib.error.URLError as e:
            if attempt < 3:
                time.sleep(2 ** attempt)
                return self._call(path, bearer, method, body, attempt + 1)
            raise PlaudError(f"Can't reach Plaud: {e.reason}") from None

    def _ensure_workspace_token(self):
        if self.workspace_token:
            return
        try:
            if not self.workspace_id:
                r = self._call("team-app/workspaces/list?need_personal_workspace=true", self.user_token)
                spaces = (r.get("data") or {}).get("workspaces") or []
                if r.get("status") != 0 or not spaces:
                    raise PlaudError(r.get("msg") or "No Plaud workspaces")
                self.workspace_id = next((w for w in spaces if w.get("workspace_type") == "0"), spaces[0])["workspace_id"]
            r = self._call("user-app/auth/workspace/token/" + urllib.parse.quote(self.workspace_id), self.user_token, "POST", {})
            self.workspace_token = (r.get("data") or {}).get("workspace_token")
        except PlaudError:
            self.workspace_token = None
        if not self.workspace_token:
            self.workspace_token = self.user_token  # fallback, as Riffado does

    def _data(self, path, method="GET", body=None):
        self._ensure_workspace_token()
        return self._call(path, self.workspace_token, method, body)

    # ---- listing --------------------------------------------------------
    def list_recordings(self):
        """[{id, filename, start_ms, duration_ms, version_ms, source}] newest first."""
        if not self.use_v4:
            out, skip = [], 0
            while True:
                r = self._data(f"file/simple/web?skip={skip}&limit=200&is_trash=0&sort_by=edit_time&is_desc=true")
                if isinstance(r.get("data_file_list"), list):
                    items = r["data_file_list"]
                    out += [{"id": f["id"], "filename": f.get("filename"), "start_ms": f.get("start_time") or 0,
                             "duration_ms": f.get("duration") or 0, "version_ms": f.get("version_ms") or f.get("edit_time") or 0,
                             "is_trans": bool(f.get("is_trans")), "is_summary": bool(f.get("is_summary"))} for f in items]
                    skip += len(items)
                    if not items or skip >= (r.get("data_file_total") or 0):
                        return out
                    continue
                if is_migrated(r):
                    self.use_v4 = True
                    break
                raise PlaudError(r.get("msg") or "Couldn't list Plaud recordings")
        out, cursor = [], None
        for _ in range(400):
            q = "sort_by=created&sort_order=desc&page_size=50" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
            r = self._data("file-app/v4/recordings/all?" + q)
            items = (r.get("data") or {}).get("items")
            if r.get("status") != 0 or items is None:
                raise PlaudError(r.get("msg") or "Invalid Plaud 4.0 listing")
            for it in items:
                fid = it.get("file_id")
                if fid:
                    start = it.get("created_at_show_ms") or 0
                    out.append({"id": fid[3:] if fid.startswith("of_") else fid, "filename": it.get("name"),
                                "start_ms": start, "duration_ms": it.get("duration_ms") or 0,
                                "version_ms": it.get("version_ms") or it.get("updated_at_show_ms") or start,
                                "is_trans": None, "is_summary": None})
            cursor = (r.get("data") or {}).get("next_cursor")
            if not cursor or not items:
                break
        return out

    # ---- v4 detail -------------------------------------------------------
    @staticmethod
    def _v4_file_id(rid):
        return rid if rid.startswith(("f_", "of_")) else "of_" + rid

    def _v4_detail(self, rid):
        fid = self._v4_file_id(rid)
        if fid not in self._detail_cache:
            r = self._data("file-app/v4/files/detail/" + urllib.parse.quote(fid))
            if r.get("status") != 0 or not r.get("data"):
                raise PlaudError(r.get("msg") or "Invalid Plaud 4.0 detail")
            self._detail_cache[fid] = r["data"]
        return self._detail_cache[fid]

    def _v4_urls(self, content_ids):
        if not content_ids:
            return {}
        r = self._data("file-app/v4/files/content/url", "POST", {"content_ids": content_ids})
        return ((r.get("data") or {}).get("url_map") or {}) if r.get("status") == 0 else {}

    # ---- audio ----------------------------------------------------------
    def audio_url(self, rid):
        if not self.use_v4:
            r = self._data(f"file/temp-url/{rid}?is_opus=0")
            if r.get("temp_url"):
                return r["temp_url"]
            if not is_migrated(r):
                raise PlaudError("No download URL")
            self.use_v4 = True
        detail = self._v4_detail(rid)
        audio = next((o for o in detail.get("objects") or [] if o.get("object_type") == "AUDIO"), None) or {}
        if audio.get("content_url"):
            return audio["content_url"]
        if audio.get("content_id"):
            url = self._v4_urls([audio["content_id"]]).get(audio["content_id"])
            if url:
                return url
        raise PlaudError("Plaud has no downloadable audio for this recording yet.")

    def download_audio(self, rid):
        url = self.audio_url(rid)
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=600) as r:
            data = r.read()
        ext = ".ogg" if data[:4] == b"OggS" else ".m4a" if data[4:8] == b"ftyp" else ".wav" if data[:4] == b"RIFF" else ".mp3"
        return data, ext

    # ---- Plaud's own transcript / summary -------------------------------
    def content(self, rid):
        """Returns (transcript dict or None, summary str or None)."""
        if self.use_v4:
            detail = self._v4_detail(rid)
            objs = detail.get("objects") or []
            missing = [o["content_id"] for o in objs if o.get("object_type") in ("TRANSCRIPT", "SUMMARY")
                       and not o.get("content_url") and o.get("content_id")]
            urls = self._v4_urls(missing)
            items = [{"type": "transaction" if o["object_type"] == "TRANSCRIPT" else "auto_sum_note",
                      "ready": o.get("task_status") == 1, "link": o.get("content_url") or urls.get(o.get("content_id"))}
                     for o in objs if o.get("object_type") in ("TRANSCRIPT", "SUMMARY")]
            inline = {}
        else:
            r = self._data(f"file/detail/{rid}")
            if is_migrated(r):
                self.use_v4 = True
                return self.content(rid)
            d = r.get("data") or {}
            items = [{"type": (c.get("data_type") or "").lower(), "id": c.get("data_id") or "",
                      "ready": c.get("task_status") == 1, "link": c.get("data_link")} for c in d.get("content_list") or []]
            inline = {p.get("data_id"): p.get("data_content") for p in d.get("pre_download_content_list") or []}

        def fetch(item):
            if item.get("id") in inline and inline[item["id"]]:
                raw = inline[item["id"]]
            elif item.get("ready") and item.get("link"):
                with urllib.request.urlopen(item["link"], timeout=120) as resp:
                    data = resp.read()
                if data[:2] == b"\x1f\x8b":
                    data = gzip.decompress(data)
                raw = data.decode("utf-8", "replace")
            else:
                return None
            try:
                return json.loads(raw)
            except (ValueError, TypeError):
                return raw

        transcript = summary = None
        t_item = next((i for i in items if i["type"] in ("transaction", "transcript") or i.get("id", "").startswith("source_transaction:")), None)
        s_item = next((i for i in items if i["type"] == "auto_sum_note" or i.get("id", "").startswith("auto_sum:")), None) \
            or next((i for i in items if i["type"] in ("sum_multi_note", "summary", "note", "ai_summary")), None)
        if t_item:
            raw = fetch(t_item)
            arr = raw if isinstance(raw, list) else next((raw.get(k) for k in ("segments", "transcript", "data")
                                                          if isinstance(raw, dict) and isinstance(raw.get(k), list)), [])
            segs = []
            for s in arr or []:
                if isinstance(s, dict):
                    sp = s.get("speaker")
                    segs.append({"start": (s.get("start_time") or 0) / 1000, "end": (s.get("end_time") or 0) / 1000,
                                 "text": s.get("content") or s.get("text") or "",
                                 "speaker": (f"Speaker {sp}" if isinstance(sp, (int, float)) else sp) or None})
            if segs:
                transcript = {"language": raw.get("language") if isinstance(raw, dict) else None, "segments": segs}
        if s_item:
            raw = fetch(s_item)
            if isinstance(raw, str):
                summary = raw.strip() or None
            elif isinstance(raw, dict):
                summary = (raw.get("ai_content") or raw.get("summary") or raw.get("content") or "").strip() or None
        return transcript, summary
