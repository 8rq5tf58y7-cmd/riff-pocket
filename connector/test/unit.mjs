// Unit tests for pure helpers (Node strips the TypeScript types).
import assert from "node:assert/strict";
import { parseDeepgram, provider, engineLabel } from "../src/transcribe.ts";
import { cleanUserToken, jwtClaims } from "../src/plaud.ts";

// Deepgram (Workers AI Nova-3) with utterances + diarization
const withUtterances = {
  results: {
    channels: [{ detected_language: "en", alternatives: [{ transcript: "Hello there. Hi Dana.", words: [] }] }],
    utterances: [
      { start: 0.08, end: 1.2, transcript: "Hello there.", speaker: 0 },
      { start: 1.5, end: 2.4, transcript: "Hi Dana.", speaker: 1 },
      { start: 2.5, end: 2.6, transcript: "  ", speaker: 1 },
    ],
  },
};
let r = parseDeepgram(withUtterances);
assert.equal(r.language, "en");
assert.deepEqual(r.segments.map((s) => [s.speaker, s.text]), [["Speaker 1", "Hello there."], ["Speaker 2", "Hi Dana."]]);

// Words only: grouped by speaker and pauses
const wordsOnly = { results: { channels: [{ alternatives: [{ words: [
  { word: "we", punctuated_word: "We", start: 0, end: 0.2, speaker: 0 },
  { word: "ship", punctuated_word: "ship.", start: 0.3, end: 0.6, speaker: 0 },
  { word: "great", punctuated_word: "Great!", start: 0.9, end: 1.1, speaker: 1 },
  { word: "later", punctuated_word: "Later", start: 5, end: 5.3, speaker: 1 },
] }] }] } };
r = parseDeepgram(wordsOnly);
assert.deepEqual(r.segments.map((s) => s.text), ["We ship.", "Great!", "Later"]);
assert.equal(r.segments[1].speaker, "Speaker 2");

// Transcript only, and empty
assert.equal(parseDeepgram({ results: { channels: [{ alternatives: [{ transcript: "Just text" }] }] } }).segments[0].text, "Just text");
assert.equal(parseDeepgram({}).segments.length, 0);

// Provider selection
assert.equal(provider({ AI: {} }), "workers-ai");
assert.equal(provider({}), "off"); // no binding, no override
assert.equal(provider({ AI: {}, TRANSCRIBE_PROVIDER: "off" }), "off");
assert.equal(provider({ TRANSCRIBE_PROVIDER: "openai" }), "openai");
assert.match(engineLabel({ AI: {} }), /Nova-3/);

// Token cleaning
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const ut = `${b64({ alg: "HS256" })}.${b64({ sub: "u", exp: Math.floor(Date.now() / 1000) + 1000 })}.s`;
assert.equal(cleanUserToken(`  Bearer "${ut}" `), ut);
assert.equal(jwtClaims(ut).sub, "u");
assert.throws(() => cleanUserToken(`${b64({ alg: "HS256" })}.${b64({ wid: "W" })}.s`), /workspace token/);
assert.throws(() => cleanUserToken("nope"), /doesn't look like/);

// Bookmarklet: finds the user token wherever web.plaud.ai keeps it, skips workspace tokens
const { bookmarkletSource } = await import("../src/pages.ts");
const src = bookmarkletSource("https://c.example");
assert.ok(!/[\\\n]/.test(src), "bookmarklet must have no backslashes or newlines");
function runBookmarklet(local, session = {}, cookie = "") {
  const store = (o) => ({ get length() { return Object.keys(o).length; }, key: (i) => Object.keys(o)[i], getItem: (k) => o[k] ?? null });
  const g = { document: { cookie }, location: { host: "web.plaud.ai", href: "" }, alerted: null };
  g.alert = (m) => { g.alerted = m; };
  // Object.keys(storage) in a browser lists the saved names; mimic that with a Proxy.
  g.localStorage = new Proxy(store(local), { ownKeys: () => Object.keys(local), getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }) });
  g.sessionStorage = new Proxy(store(session), { ownKeys: () => Object.keys(session), getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }) });
  new Function("localStorage", "sessionStorage", "document", "location", "alert", src)(g.localStorage, g.sessionStorage, g.document, g.location, g.alert);
  return g;
}
const wt = `${b64({ alg: "HS256" })}.${b64({ wid: "W", ut_ref: "x", exp: 9e9 })}.s`;
const ut2 = `${b64({ alg: "HS256" })}.${b64({ sub: "u2", exp: 8e9 })}.s`;
let g = runBookmarklet({ pld_tokenstr: `"${ut}"` });
assert.ok(g.location.href.startsWith("https://c.example/setup#token=" + encodeURIComponent(ut) + "&from="));
g = runBookmarklet({ "persist:auth": JSON.stringify({ accessToken: `bearer ${ut2}`, workspace: wt }) });
assert.equal(g.location.href, "https://c.example/setup#token=" + encodeURIComponent(ut2) + "&from=persist%3Aauth");
g = runBookmarklet({}, {}, `pld_ut=${ut}; theme=dark`);
assert.ok(g.location.href.startsWith("https://c.example/setup#token=" + encodeURIComponent(ut) + "&from="));
g = runBookmarklet({ lang: "en", only_wt: wt });
assert.equal(g.location.href, "");
assert.match(g.alerted, /No Plaud sign-in this button can read on web\.plaud\.ai.*lang, only_wt/);
// A profile JWT (email/id/name, no expiry) is not a sign-in: skipped, and refused if pasted
const profile = `${b64({ alg: "HS256" })}.${b64({ email: "a@b.c", id: "1", name: "A" })}.s`;
g = runBookmarklet({ user_info_token: profile });
assert.equal(g.location.href, "");
g = runBookmarklet({ user_info_token: profile }, {}, `pld_ut=${ut}`);
assert.ok(g.location.href.includes(encodeURIComponent(ut)));
assert.throws(() => cleanUserToken(profile), /profile token/);

// Plaud 4.0 web session: the bookmarklet reads pld_session.* (Sept 2026 web app)
const sessWT = `${b64({ alg: "HS256", typ: "WT" })}.${b64({ wid: "ws_1", client_id: "web", exp: Math.floor(Date.now() / 1000) + 3600 })}.s`;
const sessWRT = `${b64({ alg: "HS256", typ: "WRT" })}.${b64({ wid: "ws_1", exp: Math.floor(Date.now() / 1000) + 30 * 86400 })}.s`;
g = runBookmarklet({
  "pld_session.workspace": JSON.stringify({ currentId: "ws_1", list: [{ workspaceId: "ws_0", domain: "https://api-x.plaud.ai" }, { workspaceId: "ws_1", domain: "https://api-euc1.plaud.ai" }] }),
  "pld_session.tokens": JSON.stringify({ byWsId: { ws_1: { token: sessWT, refreshToken: sessWRT } } }),
  pld_DEVICE_ID: '"dev-9"',
  "pld_x:frillSsoToken": profile,
});
const sent = JSON.parse(decodeURIComponent(g.location.href.match(/#session=([^&]+)/)[1]));
assert.deepEqual(sent, { workspaceId: "ws_1", domain: "https://api-euc1.plaud.ai", token: sessWT, refreshToken: sessWRT, deviceId: "dev-9" });

// The connector renews an expired session token, sends the workspace scope, and saves the rotated pair
const { Plaud, connectSession } = await import("../src/plaud.ts");
const oldWT = `${b64({ alg: "HS256", typ: "WT" })}.${b64({ wid: "ws_1", client_id: "web", exp: Math.floor(Date.now() / 1000) - 60 })}.s`;
const newWT = `${b64({ alg: "HS256", typ: "WT" })}.${b64({ wid: "ws_1", client_id: "web", exp: Math.floor(Date.now() / 1000) + 7200 })}.s`;
const calls = [];
let revokeOnce = false;
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(url), h = init.headers ?? {};
  calls.push({ path: u.pathname, auth: h.Authorization, scope: h["x-scope-id"], platform: h["app-platform"], device: h["x-device-id"], host: u.host });
  const json = (o) => new Response(JSON.stringify(o), { headers: { "content-type": "application/json" } });
  if (u.pathname === "/user-app/auth/workspace/refresh/ws_1") return json({ status: 0, data: { workspace_token: newWT, refresh_token: "rotated.wrt.x" } });
  if (u.pathname === "/file-app/v4/recordings/all") {
    if (revokeOnce) { revokeOnce = false; return json({ status: -419, msg: "WT_EXPIRED" }); }
    return json({ status: 0, data: { items: [{ file_id: "of_r1", name: "Standup", created_at_show_ms: 5, duration_ms: 1000 }], next_cursor: null } });
  }
  return json({ status: -1, msg: "unexpected " + u.pathname });
};
const saved = [];
const creds = { apiBase: "https://api-euc1.plaud.ai", workspaceId: "ws_1", session: { workspaceToken: oldWT, refreshToken: sessWRT, deviceId: "dev-9" } };
let recs = await new Plaud(creds, undefined, async (c) => { saved.push(structuredClone(c)); }).recent(5);
assert.equal(recs[0].id, "r1");
assert.deepEqual(calls.map((c) => c.path), ["/user-app/auth/workspace/refresh/ws_1", "/file-app/v4/recordings/all"]);
assert.equal(calls[0].auth, `Bearer ${sessWRT}`);
assert.deepEqual([calls[1].auth, calls[1].scope, calls[1].platform, calls[1].device, calls[1].host], [`Bearer ${newWT}`, "ws_1", "web", "dev-9", "api-euc1.plaud.ai"]);
assert.equal(saved.length, 1);
assert.deepEqual(saved[0].session, { workspaceToken: newWT, refreshToken: "rotated.wrt.x", deviceId: "dev-9" });

// A still-valid token revoked early (-419): renew once and retry
calls.length = 0; revokeOnce = true;
recs = await new Plaud({ ...creds, session: { workspaceToken: newWT, refreshToken: sessWRT } }).recent(5);
assert.equal(recs.length, 1);
assert.deepEqual(calls.map((c) => c.path), ["/file-app/v4/recordings/all", "/user-app/auth/workspace/refresh/ws_1", "/file-app/v4/recordings/all"]);

// connectSession: from the bookmarklet's JSON to saved credentials
const conn = await connectSession(JSON.stringify(sent));
assert.equal(conn.creds.apiBase, "https://api-euc1.plaud.ai");
assert.equal(conn.creds.workspaceId, "ws_1");
assert.equal(conn.recordings, 1);
await assert.rejects(connectSession(JSON.stringify({ ...sent, refreshToken: "" })), /incomplete/);
await assert.rejects(connectSession(JSON.stringify({ ...sent, domain: "https://evil.example" })), /Not a Plaud API host/);

// Audio format from the first bytes: Plaud 4.0 serves Ogg Opus with no type or extension
const { sniffAudio } = await import("../src/plaud.ts");
const bytes = (s, pad = 16) => { const a = new Uint8Array(Math.max(pad, s.length)); [...s].forEach((c, i) => (a[i] = c.charCodeAt(0))); return a; };
assert.equal(sniffAudio(bytes("OggS")), "audio/ogg");
assert.equal(sniffAudio(bytes("ID3")), "audio/mpeg");
assert.equal(sniffAudio(Uint8Array.from([0xff, 0xfb, 0x90, 0])), "audio/mpeg");
assert.equal(sniffAudio(bytes("RIFF\0\0\0\0WAVE")), "audio/wav");
assert.equal(sniffAudio(bytes("\0\0\0\x20ftypM4A ")), "audio/mp4");
assert.equal(sniffAudio(bytes("hello")), null);

// audio(): a v4 presigned link with no type or extension still reaches speech-to-text as Ogg, bytes intact
const oggBytes = new Uint8Array([...bytes("OggS", 4), 1, 2, 3, 4, 5]);
globalThis.fetch = async (url) => {
  const u = new URL(url);
  const json = (o) => new Response(JSON.stringify(o), { headers: { "content-type": "application/json" } });
  if (u.pathname.startsWith("/file-app/v4/files/detail/")) return json({ status: 0, data: { objects: [{ object_type: "AUDIO", content_url: "https://s3.example/obj/abc?sig=1" }] } });
  if (u.host === "s3.example") return new Response(new ReadableStream({ start(c) { c.enqueue(oggBytes.slice(0, 6)); c.enqueue(oggBytes.slice(6)); c.close(); } }), { headers: { "content-type": "binary/octet-stream" } });
  return json({ status: -1 });
};
const a = await new Plaud({ ...creds, session: { workspaceToken: newWT, refreshToken: sessWRT } }).audio("f_rec");
assert.equal(a.contentType, "audio/ogg");
assert.deepEqual(new Uint8Array(await new Response(a.body).arrayBuffer()), oggBytes);

// Whisper fallback (Workers AI): segments or plain text, and base64 of large inputs
const { parseWhisper, base64 } = await import("../src/transcribe.ts");
assert.deepEqual(parseWhisper({ transcription_info: { language: "en" }, segments: [{ start: 0, end: 2.5, text: " Hi there. " }, { start: 3, end: 4, text: " " }] }),
  { language: "en", segments: [{ start: 0, end: 2.5, text: "Hi there.", speaker: null }] });
assert.equal(parseWhisper({ text: "Just text" }).segments[0].text, "Just text");
assert.equal(parseWhisper({}).segments.length, 0);
const big = Uint8Array.from({ length: 100_000 }, (_, i) => i % 251);
assert.equal(base64(big), Buffer.from(big).toString("base64"));

// Deepgram's own API: setting the key opts in; it transcribes by link, with speaker labels
const { transcribeUrl } = await import("../src/transcribe.ts");
assert.equal(provider({ AI: {}, TRANSCRIBE_PROVIDER: "workers-ai", DEEPGRAM_API_KEY: "k" }), "deepgram");
assert.equal(provider({ AI: {}, TRANSCRIBE_PROVIDER: "openai", DEEPGRAM_API_KEY: "k" }), "openai");
assert.equal(provider({ AI: {}, TRANSCRIBE_PROVIDER: "deepgram" }), "off");
assert.equal(engineLabel({ DEEPGRAM_API_KEY: "k" }), "Deepgram Nova-3");
let dg;
globalThis.fetch = async (url, init) => {
  dg = { url: new URL(url), init };
  return new Response(JSON.stringify(withUtterances), { headers: { "content-type": "application/json" } });
};
const out = await transcribeUrl({ DEEPGRAM_API_KEY: "test-key", DEEPGRAM_MIP_OPT_OUT: "true" }, "https://s3.example/rec.ogg?sig=1");
assert.equal(dg.url.origin + dg.url.pathname, "https://api.deepgram.com/v1/listen");
assert.deepEqual(["model", "diarize", "utterances", "detect_language", "mip_opt_out"].map((k) => dg.url.searchParams.get(k)), ["nova-3", "true", "true", "true", "true"]);
assert.equal(dg.init.headers.Authorization, "Token test-key");
assert.deepEqual(JSON.parse(dg.init.body), { url: "https://s3.example/rec.ogg?sig=1" });
assert.deepEqual(out.segments.map((s) => s.speaker), ["Speaker 1", "Speaker 2"]);
await transcribeUrl({ DEEPGRAM_API_KEY: "k", TRANSCRIBE_LANGUAGE: "en" }, "https://x.example/a");
assert.equal(dg.url.searchParams.get("language"), "en");
assert.equal(dg.url.searchParams.get("mip_opt_out"), null);
globalThis.fetch = async () => new Response(JSON.stringify({ err_msg: "Invalid credentials." }), { status: 401 });
await assert.rejects(transcribeUrl({ DEEPGRAM_API_KEY: "bad" }, "https://x.example/a"), /HTTP 401\): Invalid credentials\.\. Check DEEPGRAM_API_KEY/);

// Ogg structure walker: chained streams and a break are reported
const { oggStructure } = await import("../src/plaud.ts");
const page = (flags, serial, body) => {
  const h = new Uint8Array(27 + 1 + body);
  h.set([0x4f, 0x67, 0x67, 0x53, 0, flags], 0);
  h[14] = serial & 255; h[26] = 1; h[27] = body;
  return h;
};
const cat = (...parts) => { const o = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let i = 0; for (const p of parts) { o.set(p, i); i += p.length; } return o; };
assert.deepEqual(oggStructure(cat(page(2, 1, 10), page(0, 1, 50), page(4, 1, 5))), { pages: 3, streams: 1, serials: 1, ends: 1, badAt: null, bytes: 27 * 3 + 3 + 65 });
const chained = cat(page(2, 1, 10), page(4, 1, 5), page(2, 2, 10), page(0, 2, 7));
assert.equal(oggStructure(chained).streams, 2);
assert.equal(oggStructure(chained).serials, 2);
const broken = cat(page(2, 1, 10), new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]), page(0, 1, 5));
assert.equal(oggStructure(broken).badAt, 38);

// splitOgg: a chained file becomes standalone streams with their playing time
const { splitOgg } = await import("../src/plaud.ts");
const opusPage = (flags, serial, granule, bodyBytes) => {
  const h = new Uint8Array(27 + 1 + bodyBytes.length);
  h.set([0x4f, 0x67, 0x67, 0x53, 0, flags], 0);
  const g = granule < 0 ? [255, 255, 255, 255, 255, 255, 255, 255] : [granule & 255, (granule >>> 8) & 255, (granule >>> 16) & 255, (granule >>> 24) & 255, 0, 0, 0, 0];
  h.set(g, 6);
  h[14] = serial; h[26] = 1; h[27] = bodyBytes.length;
  h.set(bodyBytes, 28);
  return h;
};
const head = (preSkip) => Uint8Array.from([...Buffer.from("OpusHead"), 1, 1, preSkip & 255, preSkip >> 8, 0x80, 0x3e, 0, 0, 0, 0, 0]);
const streamA = cat(opusPage(2, 1, 0, head(312)), opusPage(0, 1, -1, new Uint8Array(30)), opusPage(4, 1, 312 + 48000 * 10, new Uint8Array(20)));
const streamB = cat(opusPage(2, 2, 0, head(0)), opusPage(4, 2, 48000 * 4, new Uint8Array(20)));
const parts = splitOgg(cat(streamA, streamB));
assert.equal(parts.length, 2);
assert.deepEqual(parts.map((p) => p.seconds), [10, 4]);
assert.deepEqual([...parts[0].bytes], [...streamA]);
assert.deepEqual([...parts[1].bytes], [...streamB]);
assert.equal(splitOgg(streamA).length, 1);

console.log("unit tests passed");
