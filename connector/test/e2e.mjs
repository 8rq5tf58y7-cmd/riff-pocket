// End-to-end test against `wrangler dev` (local workerd + local D1/KV).
// Plays both sides: the Riff Pocket iPhone app (sync API) and Claude (OAuth + MCP).
//   BASE=https://localhost:8788 OWNER_PASSWORD=... SYNC_KEY=... node test/e2e.mjs
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { noteIdForPlaud } from "../src/ids.ts";

const BASE = process.env.BASE ?? "https://localhost:8788";
const PASSWORD = process.env.OWNER_PASSWORD;
const SYNC_KEY = process.env.SYNC_KEY;
const CALLBACK = "https://claude.ai/api/mcp/auth_callback";
let passed = 0;
const step = (name) => { passed++; console.log(`  ✓ ${name}`); };
const b64url = (buf) => Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// ---------------------------------------------------------------- shared id
assert.equal(noteIdForPlaud("f_abc123"), "39126D8B-41E6-57D6-B88A-2CB31BE9809F");
step("note id matches the iPhone app and Riff Desk");

// ---------------------------------------------------------------- phone sync API
const sync = (path, method = "GET", body, key = SYNC_KEY) =>
  fetch(`${BASE}/api/v1/${path}`, { method, headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" }, body: body && JSON.stringify(body) });

assert.equal((await sync("info", "GET", undefined, "wrong-key-wrong-key")).status, 401);
step("sync API rejects a wrong key");
const now = Date.now() / 1000;
assert.equal((await sync("folders/F-WORK", "PUT", { id: "F-WORK", name: "Work", updatedAt: now })).status, 200);
const pricing = {
  id: noteIdForPlaud("f_pricing1"), title: "Q4 Pricing Decision With Dana", createdAt: now - 3600, updatedAt: now, duration: 1820,
  source: "plaud", plaudId: "f_pricing1", folderId: "F-WORK",
  transcript: { segments: [
    { start: 0, end: 30, text: "Let's lock the Q4 pricing at the 12 dollar tier.", speaker: "Dana" },
    { start: 80, end: 95, text: "Sam owns the pricing page update by Friday.", speaker: "Sam" },
  ] },
  summary: "## Summary\n- Q4 pricing locked at $12 [00:00:00]\n## Action items\n- Sam — pricing page — Friday [00:01:20]",
  attachments: [{ id: "A1", name: "competitors.pdf", text: "Acme charges $15, Globex $11", deleted: false }],
};
const lecture = { id: "N-LECTURE", title: "Lecture Wave Interference", createdAt: now - 90_000, updatedAt: now, duration: 3000,
  source: "mic", summary: "## Overview\n- Double-slit experiment", attachments: [] };
for (const n of [pricing, lecture, { ...lecture, id: "N-OLD", title: "Old Note" }]) {
  assert.equal((await sync(`notes/${n.id}`, "PUT", n)).status, 200);
}
const pruned = await (await sync("notes/prune", "POST", { keep: [pricing.id, lecture.id] })).json();
assert.equal(pruned.removed, 1);
const info = await (await sync("info")).json();
assert.equal(info.notes, 2);
step("iPhone pushes folders and notes; prune removes deleted ones");

// ---------------------------------------------------------------- discovery
const unauth = await fetch(`${BASE}/mcp`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
assert.equal(unauth.status, 401);
const challenge = unauth.headers.get("www-authenticate") ?? "";
const rmUrl = challenge.match(/resource_metadata="([^"]+)"/)?.[1];
assert.ok(rmUrl, `401 must point at resource metadata, got: ${challenge}`);
const rm = await (await fetch(rmUrl)).json();
assert.equal(rm.resource, `${BASE}/mcp`);
const issuer = rm.authorization_servers[0];
const as = await (await fetch(`${issuer}/.well-known/oauth-authorization-server`)).json();
assert.ok(as.code_challenge_methods_supported.includes("S256"));
assert.ok(as.registration_endpoint, "DCR endpoint advertised");
assert.equal(as.client_id_metadata_document_supported, true);
step("401 → protected resource metadata → authorization server metadata (S256, DCR, CIMD)");

// ---------------------------------------------------------------- DCR (how Claude registers)
const reg = await (await fetch(as.registration_endpoint, {
  method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ client_name: "Claude", redirect_uris: [CALLBACK], token_endpoint_auth_method: "none",
                         grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }),
})).json();
assert.ok(reg.client_id);
step("dynamic client registration");

// ---------------------------------------------------------------- consent with password
const verifier = b64url(randomBytes(32));
const challengeS256 = b64url(createHash("sha256").update(verifier).digest());
const state = b64url(randomBytes(8));
const authUrl = new URL(as.authorization_endpoint);
Object.entries({ response_type: "code", client_id: reg.client_id, redirect_uri: CALLBACK, scope: "notes:read offline_access",
  state, code_challenge: challengeS256, code_challenge_method: "S256", resource: `${BASE}/mcp` })
  .forEach(([k, v]) => authUrl.searchParams.set(k, v));
const consent = await fetch(authUrl, { redirect: "manual" });
assert.equal(consent.status, 200);
const html = await consent.text();
assert.match(html, /Allow Claude to read your notes\?/);
assert.match(html, /claude\.ai/); // redirect host shown
const handle = html.match(/name="handle" value="([^"]+)"/)[1];
const cookies = consent.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
const post = (password, decision = "approve") => fetch(authUrl.origin + authUrl.pathname, {
  method: "POST", redirect: "manual",
  headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookies },
  body: new URLSearchParams({ handle, password, decision }),
});
assert.equal((await post("not-the-password")).status, 401);
step("consent page shows client and redirect host; wrong password refused");
const approved = await post(PASSWORD);
assert.equal(approved.status, 302);
const back = new URL(approved.headers.get("location"));
assert.equal(back.origin + back.pathname, CALLBACK);
assert.equal(back.searchParams.get("state"), state);
const code = back.searchParams.get("code");
assert.ok(code);
step("right password → redirect to Claude's callback with code and state");

// ---------------------------------------------------------------- token exchange
const tokenRes = await fetch(as.token_endpoint, {
  method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: CALLBACK, client_id: reg.client_id,
                              code_verifier: verifier, resource: `${BASE}/mcp` }),
});
const tokens = await tokenRes.json();
assert.equal(tokenRes.status, 200, JSON.stringify(tokens));
assert.ok(tokens.access_token && tokens.refresh_token);
step("PKCE code exchange returns access + refresh tokens");

// ---------------------------------------------------------------- MCP
let rpcId = 0;
const rpc = async (method, params, token = tokens.access_token) => {
  const res = await fetch(`${BASE}/mcp`, {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  assert.equal(res.status, 200, `${method} → ${res.status}`);
  const body = await res.json();
  assert.ok(!body.error, `${method}: ${JSON.stringify(body.error)}`);
  return body.result;
};
const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "claude-ai", version: "1" } });
assert.equal(init.protocolVersion, "2025-06-18");
assert.ok(init.capabilities.tools && init.instructions);
const note = await fetch(`${BASE}/mcp`, { method: "POST", headers: { Authorization: `Bearer ${tokens.access_token}`, "Content-Type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) });
assert.equal(note.status, 202);
const { tools } = await rpc("tools/list", {});
assert.deepEqual(tools.map((t) => t.name).sort(),
  ["get_note", "list_folders", "list_recent_notes", "plaud_get_recording", "plaud_recent_recordings", "search_notes"]);
assert.ok(tools.every((t) => t.annotations?.readOnlyHint === true));
step("initialize, notifications (202), tools/list — 6 read-only tools");

const text = (r) => r.content.map((c) => c.text).join("\n");
const found = await rpc("tools/call", { name: "search_notes", arguments: { query: "Globex price" } });
assert.match(text(found), /Q4 Pricing Decision With Dana/);
assert.match(text(found), new RegExp(pricing.id));
const inFolder = await rpc("tools/call", { name: "search_notes", arguments: { query: "", folder: "work" } });
assert.match(text(inFolder), /Q4 Pricing/);
assert.doesNotMatch(text(inFolder), /Lecture/);
const full = await rpc("tools/call", { name: "get_note", arguments: { id: pricing.id } });
assert.match(text(full), /## Summary/);
assert.match(text(full), /competitors\.pdf/);
assert.match(text(full), /\[00:01:20\] Sam: Sam owns the pricing page/);
const recent = await rpc("tools/call", { name: "list_recent_notes", arguments: { days: 7 } });
assert.match(text(recent), /Lecture Wave Interference/);
const folders = await rpc("tools/call", { name: "list_folders", arguments: {} });
assert.match(text(folders), /Work \(1\)/);
const missing = await rpc("tools/call", { name: "get_note", arguments: { id: "nope" } });
assert.equal(missing.isError, true);
const plaud = await rpc("tools/call", { name: "plaud_recent_recordings", arguments: {} });
assert.equal(plaud.isError, true);
assert.match(text(plaud), /isn't connected/);
step("search (keywords, attachments, folder), get_note, recent, folders, friendly errors");

const { prompts } = await rpc("prompts/list", {});
assert.deepEqual(prompts.map((p) => p.name).sort(), ["save_to_notion", "weekly_digest"]);
const notion = await rpc("prompts/get", { name: "save_to_notion", arguments: { which: "today" } });
assert.match(notion.messages[0].content.text, /Notion connector/);
step("prompts: save_to_notion, weekly_digest");

const badToken = await fetch(`${BASE}/mcp`, { method: "POST", headers: { Authorization: "Bearer nope", "Content-Type": "application/json" }, body: "{}" });
assert.equal(badToken.status, 401);
const refreshed = await (await fetch(as.token_endpoint, {
  method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: tokens.refresh_token, client_id: reg.client_id, resource: `${BASE}/mcp` }),
})).json();
assert.ok(refreshed.access_token && refreshed.refresh_token !== tokens.refresh_token, "refresh rotates");
await rpc("ping", {}, refreshed.access_token);
step("invalid token refused; refresh token rotates and the new token works");

const landing = await (await fetch(`${BASE}/`)).text();
assert.match(landing, /\/mcp<\/code>/);
step("landing page shows the connector URL");

console.log(`\n${passed} checks passed.`);
