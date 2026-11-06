/**
 * Riff Pocket connector — a remote MCP server for claude.ai, Claude Desktop and the Claude mobile apps.
 *
 *   /mcp            MCP (Streamable HTTP), OAuth-protected (scope notes:read)
 *   /authorize      consent page: you approve Claude with your OWNER_PASSWORD
 *   /oauth/*, /.well-known/*   OAuth 2.1 server (DCR + CIMD + PKCE) — @cloudflare/workers-oauth-provider
 *   /setup          connect your Plaud account (password-protected); cron syncs it every 30 min
 *   /api/v1/*       optional one-way mirror from the Riff Pocket iPhone app (Bearer SYNC_KEY)
 *   /               landing page with setup steps
 */
import { AuthorizationError, OAuthProvider, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { mcpFetch, SERVER_VERSION } from "./mcp";
import { consentPage, landingPage, messagePage, setupPage, type SetupView } from "./pages";
import { connectToken, PlaudBlocked, sendCode, tokenExpiry, verifyCode, type PlaudCreds } from "./plaud";
import { pruneNotes, setSetting, getSetting, upsertFolder, upsertNote, type DeskNote } from "./store";
import { syncPlaud, type SyncResult } from "./sync";

export interface Env {
  OAUTH_KV: KVNamespace;
  DB: D1Database;
  OWNER_PASSWORD: string;
  SYNC_KEY: string;
  /** Optional: pin the public origin (e.g. https://notes.example.com); other hostnames are refused. */
  PUBLIC_ORIGIN?: string;
  /** Tests only: send Plaud API calls to a fake Plaud server. Never set in production. */
  PLAUD_API_OVERRIDE?: string;
  OAUTH_PROVIDER: OAuthHelpers;
}

const SCOPES = ["notes:read", "offline_access"];
const MAX_ATTEMPTS = 8; // wrong passwords per 15 minutes per IP

// ---------------------------------------------------------------- helpers

async function sha256(s: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
}

/** Constant-time comparison (hashing first makes the lengths equal). */
async function secretEquals(given: string, expected: string): Promise<boolean> {
  if (!expected) return false;
  const [a, b] = await Promise.all([sha256(given), sha256(expected)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

const json = (data: unknown, status = 200) => Response.json(data, { status, headers: { "Cache-Control": "no-store" } });

async function tooManyAttempts(env: Env, ip: string): Promise<boolean> {
  return Number((await env.OAUTH_KV.get(`riff-ratelimit:${ip}`)) ?? 0) >= MAX_ATTEMPTS;
}

async function recordFailure(env: Env, ip: string) {
  const key = `riff-ratelimit:${ip}`;
  const n = Number((await env.OAUTH_KV.get(key)) ?? 0) + 1;
  await env.OAUTH_KV.put(key, String(n), { expirationTtl: 900 });
}

// ---------------------------------------------------------------- /authorize

async function authorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  if (!env.OWNER_PASSWORD || env.OWNER_PASSWORD.length < 8) {
    return messagePage("Set a connector password first", "Run `npx wrangler secret put OWNER_PASSWORD` (8+ characters), then try connecting again.", 503);
  }

  if (request.method === "GET") {
    let authRequest;
    try {
      authRequest = await oauth.parseAuthRequest(request);
    } catch (e) {
      if (!(e instanceof AuthorizationError)) throw e;
      if (e.redirectTo) return Response.redirect(e.redirectTo, 302);
      return messagePage("Can't connect", e.description ?? "Invalid authorization request.");
    }
    const details = await oauth.describeConsent(authRequest);
    const consent = await oauth.beginConsent(authRequest);
    consent.headers.set("Content-Type", "text/html; charset=utf-8");
    consent.headers.set("X-Frame-Options", "DENY");
    consent.headers.set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'");
    return new Response(consentPage({ ...details, handle: consent.handle }), { headers: consent.headers });
  }

  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  const form = await request.formData();
  const handle = String(form.get("handle") ?? "");
  try {
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (await tooManyAttempts(env, ip)) {
      return messagePage("Too many attempts", "Wait 15 minutes, then start connecting again from Claude.", 429);
    }
    if (!(await secretEquals(String(form.get("password") ?? ""), env.OWNER_PASSWORD))) {
      await recordFailure(env, ip);
      return messagePage("Wrong password", "Go back and try again. (The handle is still valid for a few minutes.)", 401);
    }
    const approved = await oauth.approveConsent(request, handle, { scope: SCOPES });
    const scope = approved.request.scope.filter((s) => SCOPES.includes(s));
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request,
      userId: "owner",
      metadata: { approvedAt: new Date().toISOString() },
      scope: scope.length ? scope : ["notes:read"],
      props: { userId: "owner" },
    });
    approved.headers.set("Location", redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (e) {
    if (e instanceof AuthorizationError) {
      return messagePage("This sign-in expired", "Start connecting again from Claude.", 400);
    }
    throw e;
  }
}

// ---------------------------------------------------------------- /setup (connect Plaud without any app)

async function setupView(env: Env, origin: string, extra: Partial<SetupView> = {}): Promise<SetupView> {
  const creds = await getSetting<PlaudCreds>(env.DB, "plaud");
  const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM notes").first<{ n: number }>();
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
  return {
    origin, nonce, notes: count?.n ?? 0,
    plaud: { connected: !!creds?.userToken, apiBase: creds?.apiBase, expires: creds?.userToken ? tokenExpiry(creds.userToken) : null },
    sync: await getSetting<SyncResult>(env.DB, "plaudSync"),
    ...extra,
  };
}

async function setup(request: Request, env: Env): Promise<Response> {
  const origin = new URL(request.url).origin;
  if (!env.OWNER_PASSWORD || env.OWNER_PASSWORD.length < 8) {
    return messagePage("Set a connector password first", "Run `npx wrangler secret put OWNER_PASSWORD` (8+ characters), then reload this page.", 503);
  }
  if (request.method === "GET") return setupPage(await setupView(env, origin));
  if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const form = await request.formData();
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const say = async (text: string, ok: boolean, extra: Partial<SetupView> = {}) =>
    setupPage(await setupView(env, origin, { message: { text, ok }, ...extra }));
  if (await tooManyAttempts(env, ip)) return say("Too many wrong passwords. Wait 15 minutes.", false);
  if (!(await secretEquals(String(form.get("password") ?? ""), env.OWNER_PASSWORD))) {
    await recordFailure(env, ip);
    return say("Wrong connector password.", false);
  }

  const action = String(form.get("action") ?? "");
  const override = env.PLAUD_API_OVERRIDE;
  try {
    if (action === "token") {
      const { creds, recordings } = await connectToken(String(form.get("token") ?? ""), String(form.get("region") ?? "") || undefined, override);
      await setSetting(env.DB, "plaud", creds);
      const r = await syncPlaud(env, 10);
      return say(`Connected to Plaud (${recordings ? "recordings found" : "no recordings yet"}). Imported ${r.added} recording${r.added === 1 ? "" : "s"}${r.pending ? `; ${r.pending} more load over the next runs` : ""}.`, !r.error);
    }
    if (action === "send_code") {
      const email = String(form.get("email") ?? "").trim();
      if (!email.includes("@")) return say("Enter the email address of your Plaud account.", false);
      const { otpToken, apiBase } = await sendCode(email, override);
      return say("Plaud emailed you a code.", true, { otp: { otpToken, apiBase, email } });
    }
    if (action === "verify_code") {
      const token = await verifyCode(String(form.get("code") ?? "").trim(), String(form.get("otp_token") ?? ""), String(form.get("api_base") ?? ""), override);
      const { creds } = await connectToken(token, undefined, override);
      await setSetting(env.DB, "plaud", { ...creds, apiBase: String(form.get("api_base") ?? creds.apiBase) });
      const r = await syncPlaud(env, 10);
      return say(`Connected. Imported ${r.added} recording${r.added === 1 ? "" : "s"}. (If your Plaud account uses Apple or Google sign-in and nothing appears, use the bookmarklet instead.)`, !r.error);
    }
    if (action === "sync") {
      const r = await syncPlaud(env, 10);
      return say(r.error ? r.error : `Synced: ${r.added} new, ${r.updated} updated${r.pending ? `, ${r.pending} still loading` : ""}.`, !r.error);
    }
    if (action === "disconnect") {
      await env.DB.prepare("DELETE FROM settings WHERE key IN ('plaud', 'plaudSync')").run();
      return say("Plaud disconnected. Notes already imported stay until you delete them.", true);
    }
    return say("Unknown action.", false);
  } catch (e) {
    const msg = e instanceof PlaudBlocked
      ? "Plaud refused the request from Cloudflare's servers (bot protection), so this connector can't read Plaud directly."
      : (e as Error).message;
    return say(msg, false);
  }
}

// ---------------------------------------------------------------- phone sync API

async function syncApi(request: Request, env: Env, path: string): Promise<Response> {
  const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!env.SYNC_KEY || env.SYNC_KEY.length < 16 || !(await secretEquals(token, env.SYNC_KEY))) {
    return json({ error: "Wrong or missing sync key." }, 401);
  }
  const parts = path.split("/").filter(Boolean); // after /api/v1/
  const method = request.method;

  if (parts[0] === "info" && method === "GET") {
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM notes").first<{ n: number }>();
    return json({ name: "Riff Pocket connector", version: SERVER_VERSION, processing: false,
                  plaudConnected: !!(await getSetting(env.DB, "plaud")), notes: count?.n ?? 0 });
  }
  if (parts[0] === "notes" && parts[1] === "prune" && method === "POST") {
    const body = (await request.json()) as { keep?: string[] };
    if (!Array.isArray(body.keep)) return json({ error: "keep must be a list of note ids" }, 400);
    return json({ removed: await pruneNotes(env.DB, body.keep.map(String)) });
  }
  if (parts[0] === "notes" && parts.length === 2 && method === "PUT") {
    const note = (await request.json()) as DeskNote;
    note.id = parts[1];
    await upsertNote(env.DB, note);
    return json({ ...note, hasAudio: false });
  }
  if (parts[0] === "notes" && parts.length === 2 && method === "DELETE") {
    await env.DB.prepare("DELETE FROM notes WHERE id = ?").bind(parts[1]).run();
    return json({ ok: true });
  }
  if (parts[0] === "folders" && parts.length === 2 && method === "PUT") {
    const f = (await request.json()) as { name: string; updatedAt?: number; deleted?: boolean };
    await upsertFolder(env.DB, { ...f, id: parts[1] });
    return json({ ok: true });
  }
  if (parts[0] === "plaud" && parts[1] === "connect" && method === "POST") {
    const c = (await request.json()) as { userToken?: string; apiBase?: string; workspaceId?: string | null };
    if (!c.userToken) return json({ error: "userToken is required" }, 400);
    await setSetting(env.DB, "plaud", { userToken: c.userToken, apiBase: c.apiBase, workspaceId: c.workspaceId ?? null });
    return json({ ok: true });
  }
  if (parts[0] === "plaud" && parts[1] === "disconnect" && method === "POST") {
    await env.DB.prepare("DELETE FROM settings WHERE key = 'plaud'").run();
    return json({ ok: true });
  }
  return json({ error: "Unknown endpoint" }, 404);
}

// ---------------------------------------------------------------- routing

const defaultHandler: ExportedHandler<Env> = {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/authorize") return authorize(request, env);
    if (url.pathname === "/setup") return setup(request, env);
    if (url.pathname.startsWith("/api/v1/")) return syncApi(request, env, url.pathname.slice("/api/v1/".length));
    if (url.pathname === "/health") return json({ ok: true, version: SERVER_VERSION });
    if (url.pathname === "/" && request.method === "GET") {
      const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM notes").first<{ n: number }>();
      return landingPage(url.origin, count?.n ?? 0, !!(await getSetting(env.DB, "plaud")));
    }
    return new Response("Not found", { status: 404 });
  },
};

const apiHandler = {
  async fetch(request: Request, env: Env, ctx: any) {
    const scopes: string[] = ctx?.auth?.scope ?? [];
    if (!scopes.includes("notes:read")) return json({ error: "insufficient_scope" }, 403);
    return mcpFetch(request, env);
  },
};

// One provider per public origin, so the same code works on *.workers.dev or a custom domain.
const providers = new Map<string, OAuthProvider<Env>>();

function providerFor(origin: string): OAuthProvider<Env> {
  let p = providers.get(origin);
  if (!p) {
    p = new OAuthProvider<Env>({
      apiRoute: "/mcp",
      apiHandler,
      defaultHandler,
      authorizeEndpoint: "/authorize",
      tokenEndpoint: "/oauth/token",
      clientRegistrationEndpoint: "/oauth/register",
      clientIdMetadataDocumentEnabled: true,
      scopesSupported: SCOPES,
      requiredScopes: ["notes:read"],
      resourceMetadata: { resource: `${origin}/mcp`, authorization_servers: [origin] },
      accessTokenTTL: 60 * 60,
      refreshTokenIdleTTL: 60 * 60 * 24 * 90, // stays connected while you keep using it
    });
    providers.set(origin, p);
  }
  return p;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const origin = new URL(request.url).origin;
    if (env.PUBLIC_ORIGIN && origin !== env.PUBLIC_ORIGIN.replace(/\/+$/, "")) {
      return new Response("Not found", { status: 404 });
    }
    return providerFor(origin).fetch(request, env, ctx);
  },

  /** Cron (every 30 minutes): pull new Plaud recordings, transcripts and summaries. */
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(syncPlaud(env, 10));
  },
} satisfies ExportedHandler<Env>;
