// A fake Plaud API for tests: classic and Plaud 4.0 shapes, workspace tokens, gzip content, email codes.
import { createServer } from "node:http";
import { gzipSync } from "node:zlib";

const b64url = (s) => Buffer.from(s).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export const jwt = (claims) => `${b64url('{"alg":"HS256","typ":"JWT"}')}.${b64url(JSON.stringify(claims))}.sig`;
export const USER_TOKEN = jwt({ sub: "user-1", exp: Math.floor(Date.now() / 1000) + 300 * 86400 });
export const WORKSPACE_TOKEN_PASTE = jwt({ sub: "user-1", ut_ref: "x", wid: "W1", exp: Math.floor(Date.now() / 1000) + 86400 });
const WT = "workspace-token-from-fake";

export function startFakePlaud(port) {
  const state = { v4: false, calls: [], extra: [] };
  const base = `http://127.0.0.1:${port}`;
  const now = Date.now();
  const transcript = [
    { start_time: 0, end_time: 4000, speaker: "Dana", content: "Welcome to the zebra launch review." },
    { start_time: 61000, end_time: 66000, speaker: 2, content: "The launch date moves to March 3." },
  ];
  const legacyFiles = () => [
    { id: "rec1", filename: "Zebra Launch Review", start_time: now - 7200_000, duration: 1_800_000, version_ms: 1000, is_trans: true, is_summary: true },
    { id: "rec2", filename: "Untranscribed Memo", start_time: now - 3600_000, duration: 60_000, version_ms: 2000, is_trans: false, is_summary: false },
  ];

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, base);
    const path = url.pathname.replace(/^\//, "");
    let body = "";
    for await (const chunk of req) body += chunk;
    const auth = (req.headers.authorization ?? "").replace(/^Bearer /, "");
    state.calls.push(`${req.method} ${path}`);
    const send = (obj, status = 200, type = "application/json") => {
      res.writeHead(status, { "Content-Type": type });
      res.end(typeof obj === "string" || Buffer.isBuffer(obj) ? obj : JSON.stringify(obj));
    };
    const needs = (token) => { if (auth !== token) { send({ msg: "unauthorized" }, 401); return false; } return true; };

    // Test control
    if (path === "__v4") { state.v4 = true; state.extra.push({ id: "f_new9", name: "Board Prep Call", created: now - 600_000, dur: 900_000, ver: 5000 }); return send({ ok: true }); }

    // Email sign-in
    if (path === "auth/otp-send-code") return send({ status: 0, token: "otp-token-1" });
    if (path === "auth/otp-login") return JSON.parse(body).code === "123456" ? send({ status: 0, access_token: USER_TOKEN }) : send({ status: -1, msg: "bad code" });

    // Workspace token (user token only)
    if (path === "team-app/workspaces/list") return needs(USER_TOKEN) && send({ status: 0, data: { workspaces: [{ workspace_id: "W1", workspace_type: "0" }] } });
    if (path === "user-app/auth/workspace/token/W1") return needs(USER_TOKEN) && send({ status: 0, data: { workspace_token: WT } });

    // Fake Whisper (OpenAI-compatible) used by the connector's transcription in tests
    if (path === "v1/audio/transcriptions") {
      state.transcriptions = (state.transcriptions ?? 0) + 1;
      if (auth !== "test-transcribe-key") return send({ error: "bad key" }, 401);
      if (!body.includes("FAKE-MP3-AUDIO")) return send({ error: "no audio received" }, 400);
      return send({ language: "en", text: "Remember to renew the parking permit.", segments: [
        { start: 0.5, end: 3.2, text: " Remember to renew the parking permit." },
        { start: 3.4, end: 6.0, text: " It expires on Friday." },
      ] });
    }
    // Audio files (no auth)
    if (path === "audio/rec2.mp3") return send(Buffer.from("ID3FAKE-MP3-AUDIO-BYTES"), 200, "audio/mpeg");

    // Content links (no auth, gzip)
    if (path === "content/trans.json.gz") return send(gzipSync(JSON.stringify(transcript)), 200, "application/octet-stream");
    if (path === "content/sum.md.gz") return send(gzipSync("## Summary\n- Launch moved to March 3 [00:01:01]"), 200, "application/octet-stream");

    if (!needs(WT)) return;
    const migratedReply = { status: -1800907, msg: "Account migrated to 4.0. Please update and reinitialize." };

    // Classic API
    if (path === "file/simple/web") return send(state.v4 ? migratedReply : { status: 0, data_file_total: 2, data_file_list: legacyFiles() });
    if (path === "file/temp-url/rec2") return send(state.v4 ? migratedReply : { status: 0, temp_url: `${base}/audio/rec2.mp3` });
    if (path === "file/detail/rec1") {
      if (state.v4) return send(migratedReply);
      return send({ status: 0, data: {
        content_list: [
          { data_id: "source_transaction:1", data_type: "transaction", task_status: 1, data_link: `${base}/content/trans.json.gz` },
          { data_id: "auto_sum:1", data_type: "auto_sum_note", task_status: 1, data_link: `${base}/content/never-fetched` },
        ],
        pre_download_content_list: [{ data_id: "auto_sum:1", data_content: JSON.stringify({ ai_content: "## Summary\n- Zebra launch reviewed", action_items: ["Dana: confirm venue"] }) }],
      } });
    }

    // Plaud 4.0 API
    if (path === "file-app/v4/recordings/all") {
      const items = [
        { file_id: "of_rec1", name: "Zebra Launch Review", created_at_show_ms: now - 7200_000, duration_ms: 1_800_000, version_ms: 1000 },
        ...state.extra.map((e) => ({ file_id: e.id, name: e.name, created_at_show_ms: e.created, duration_ms: e.dur, version_ms: e.ver })),
      ];
      return send({ status: 0, data: { items, next_cursor: null } });
    }
    if (path === "file-app/v4/files/detail/f_new9") {
      return send({ status: 0, data: { objects: [
        { object_type: "AUDIO", content_id: "c-audio" },
        { object_type: "TRANSCRIPT", content_id: "c-trans", task_status: 1 },
        { object_type: "SUMMARY", content_id: "c-sum", content_url: `${base}/content/sum.md.gz`, task_status: 1 },
      ] } });
    }
    if (path === "file-app/v4/files/content/url") {
      const ids = JSON.parse(body).content_ids ?? [];
      return send({ status: 0, data: { url_map: Object.fromEntries(ids.map((id) => [id, `${base}/content/trans.json.gz`])) } });
    }
    send({ status: -1, msg: `fake: unknown ${path}` }, 404);
  });

  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ state, close: () => server.close(), base })));
}
