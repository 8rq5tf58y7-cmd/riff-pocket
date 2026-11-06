/**
 * Plaud cloud client for the Worker — ported from Riffado's src/lib/plaud (AGPL-3.0), including
 * Plaud 4.0 support from riffado/riffado#328 and the email-code sign-in.
 *
 * Plaud sits behind Cloudflare bot protection and may refuse server traffic; that surfaces as
 * PlaudBlocked so the setup page and tools can say so plainly.
 */

const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const MIGRATED = -1800907;
const VALID_HOST = /^https:\/\/([a-z0-9-]+\.)*plaud\.(ai|cn)$/;

export const REGIONS: Record<string, string> = {
  global: "https://api.plaud.ai",
  eu: "https://api-euc1.plaud.ai",
  apac: "https://api-apse1.plaud.ai",
  china: "https://api.plaud.cn",
};

export interface PlaudCreds { userToken: string; apiBase?: string; workspaceId?: string | null }
export interface PlaudRecording {
  id: string;
  title: string;
  startMs: number;
  durationMs: number;
  versionMs: number;
  /** false = Plaud says there's nothing to fetch; null = unknown (Plaud 4.0 listings). */
  hasTranscript: boolean | null;
  hasSummary: boolean | null;
}
export interface Segment { start: number; end: number; text: string; speaker: string | null }

export class PlaudError extends Error {}
export class PlaudBlocked extends PlaudError {}

const migrated = (b: any) => b?.status === MIGRATED || /migrated to 4\.0/i.test(String(b?.msg ?? ""));

function headers(bearer?: string): Record<string, string> {
  return {
    ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}),
    "Content-Type": "application/json",
    "User-Agent": UA,
    Origin: "https://web.plaud.ai",
    Referer: "https://web.plaud.ai/",
  };
}

async function parse(res: Response): Promise<any> {
  if (res.status === 401) throw new PlaudError("Plaud rejected the sign-in. Connect Plaud again on the connector's setup page.");
  if (res.status === 403 || res.status === 503 || res.headers.get("cf-mitigated")) {
    throw new PlaudBlocked("Plaud refused this request from Cloudflare's servers (bot protection).");
  }
  if (!res.ok) throw new PlaudError(`Plaud HTTP ${res.status}`);
  const text = await res.text();
  try {
    return JSON.parse(text || "{}");
  } catch {
    throw new PlaudBlocked("Plaud returned a challenge page instead of data (bot protection).");
  }
}

function baseFor(apiBase: string | undefined, override?: string): string {
  if (override) return override.replace(/\/+$/, ""); // tests only (PLAUD_API_OVERRIDE)
  const base = (apiBase || REGIONS.global).replace(/\/+$/, "");
  if (!VALID_HOST.test(base)) throw new PlaudError(`Not a Plaud API host: ${base}`);
  return base;
}

// ---------------------------------------------------------------- sign-in helpers

export function jwtClaims(token: string): Record<string, any> | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/") + "===".slice((parts[1].length + 3) % 4);
    return JSON.parse(atob(b64));
  } catch {
    return null;
  }
}

/** Cleans a pasted token and rejects the shapes that can't work (Riffado #203). */
export function cleanUserToken(raw: string): string {
  let t = raw.trim().replace(/^bearer\s+/i, "").replace(/^"+|"+$/g, "").trim();
  if (t.split(".").length !== 3) throw new PlaudError("That doesn't look like a Plaud token (expected a long value starting with eyJ).");
  const c = jwtClaims(t);
  if (c && (typeof c.ut_ref === "string" || typeof c.wid === "string")) {
    throw new PlaudError("That's a short-lived workspace token (~24 h). Use the bookmarklet, or copy localStorage 'pld_tokenstr' on web.plaud.ai instead of an Authorization header.");
  }
  if (c && typeof c.exp === "number" && c.exp * 1000 < Date.now()) throw new PlaudError("This Plaud token has expired. Sign in to web.plaud.ai again.");
  return t;
}

export function tokenExpiry(token: string): number | null {
  const exp = jwtClaims(token)?.exp;
  return typeof exp === "number" ? exp : null;
}

/** Email one-time code, step 1 (follows Plaud's regional redirect, status -302). */
export async function sendCode(email: string, override?: string): Promise<{ otpToken: string; apiBase: string }> {
  let base = baseFor(REGIONS.global, override);
  for (let i = 0; i < 4; i++) {
    const body = await parse(await fetch(`${base}/auth/otp-send-code`, { method: "POST", headers: headers(), body: JSON.stringify({ username: email }) }));
    if (body?.status === -302 && body?.data?.domains?.api) {
      base = baseFor(String(body.data.domains.api), override);
      continue;
    }
    if (body?.status !== 0 || !body?.token) throw new PlaudError(body?.msg || "Plaud couldn't send a code to that address.");
    return { otpToken: body.token, apiBase: base };
  }
  throw new PlaudError("Too many region redirects from Plaud.");
}

/** Email one-time code, step 2. Only for accounts created with email (Apple/Google sign-ups need the token). */
export async function verifyCode(code: string, otpToken: string, apiBase: string, override?: string): Promise<string> {
  const body = await parse(await fetch(`${baseFor(apiBase, override)}/auth/otp-login`, {
    method: "POST", headers: headers(), body: JSON.stringify({ code, token: otpToken }),
  }));
  const token = body?.access_token ?? body?.data?.access_token;
  if (!token) throw new PlaudError(body?.msg || "That code didn't work.");
  return token;
}

/** Validates a user token, trying the preferred region first. Returns working credentials. */
export async function connectToken(rawToken: string, preferred?: string, override?: string): Promise<{ creds: PlaudCreds; recordings: number }> {
  const userToken = cleanUserToken(rawToken);
  const bases = Array.from(new Set([preferred && REGIONS[preferred] ? REGIONS[preferred] : preferred, ...Object.values(REGIONS)].filter(Boolean) as string[]));
  let last: unknown = null;
  for (const apiBase of override ? [REGIONS.global] : bases) {
    try {
      const plaud = new Plaud({ userToken, apiBase }, override);
      const recs = await plaud.recent(5);
      return { creds: { userToken, apiBase, workspaceId: plaud.workspaceId ?? null }, recordings: recs.length };
    } catch (e) {
      if (e instanceof PlaudBlocked) throw e; // same for every region
      last = e;
    }
  }
  throw last instanceof Error ? last : new PlaudError("Plaud didn't accept that token in any region.");
}

// ---------------------------------------------------------------- client

export class Plaud {
  private base: string;
  private wt?: string;
  private v4 = false;
  private detailCache = new Map<string, any>();
  workspaceId?: string | null;
  private creds: PlaudCreds;

  constructor(creds: PlaudCreds, override?: string) {
    this.creds = creds;
    this.base = baseFor(creds.apiBase, override);
    this.workspaceId = creds.workspaceId;
  }

  private async call(path: string, bearer: string, init: RequestInit = {}): Promise<any> {
    return parse(await fetch(`${this.base}/${path.replace(/^\//, "")}`, { ...init, headers: headers(bearer) }));
  }

  private async token(): Promise<string> {
    if (this.wt) return this.wt;
    try {
      if (!this.workspaceId) {
        const r = await this.call("team-app/workspaces/list?need_personal_workspace=true", this.creds.userToken);
        const spaces = r?.data?.workspaces ?? [];
        this.workspaceId = (spaces.find((w: any) => w.workspace_type === "0") ?? spaces[0])?.workspace_id ?? null;
      }
      if (this.workspaceId) {
        const r = await this.call(`user-app/auth/workspace/token/${encodeURIComponent(this.workspaceId)}`, this.creds.userToken, { method: "POST", body: "{}" });
        this.wt = r?.data?.workspace_token;
      }
    } catch (e) {
      if (e instanceof PlaudBlocked) throw e;
    }
    this.wt ||= this.creds.userToken; // fallback, as Riffado does
    return this.wt;
  }

  private async data(path: string, init?: RequestInit) {
    return this.call(path, await this.token(), init);
  }

  /** Most recent recordings, newest first (pages through Plaud 4.0's cursor listing). */
  async recent(limit = 50): Promise<PlaudRecording[]> {
    if (!this.v4) {
      const r = await this.data(`file/simple/web?skip=0&limit=${limit}&is_trash=0&sort_by=start_time&is_desc=true`);
      if (Array.isArray(r?.data_file_list)) {
        return r.data_file_list.map((f: any) => ({
          id: String(f.id), title: f.filename || "Recording", startMs: f.start_time || 0, durationMs: f.duration || 0,
          versionMs: f.version_ms || f.edit_time || f.start_time || 0,
          hasTranscript: typeof f.is_trans === "boolean" ? f.is_trans : null,
          hasSummary: typeof f.is_summary === "boolean" ? f.is_summary : null,
        }));
      }
      if (!migrated(r)) throw new PlaudError(r?.msg || "Couldn't list Plaud recordings");
      this.v4 = true;
    }
    const out: PlaudRecording[] = [];
    let cursor: string | undefined;
    while (out.length < limit) {
      const q = `sort_by=created&sort_order=desc&page_size=${Math.min(50, limit - out.length)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
      const r = await this.data(`file-app/v4/recordings/all?${q}`);
      const items = r?.data?.items;
      if (r?.status !== 0 || !Array.isArray(items)) throw new PlaudError(r?.msg || "Invalid Plaud 4.0 listing");
      for (const i of items) {
        if (!i.file_id) continue;
        const start = i.created_at_show_ms || 0;
        out.push({ id: String(i.file_id).replace(/^of_/, ""), title: i.name || "Recording", startMs: start, durationMs: i.duration_ms || 0,
                   versionMs: i.version_ms || i.updated_at_show_ms || start, hasTranscript: null, hasSummary: null });
      }
      cursor = r.data.next_cursor;
      if (!cursor || !items.length) break;
    }
    return out.slice(0, limit);
  }

  private async v4Detail(id: string) {
    const fid = /^(f_|of_)/.test(id) ? id : `of_${id}`;
    if (!this.detailCache.has(fid)) {
      const r = await this.data(`file-app/v4/files/detail/${encodeURIComponent(fid)}`);
      if (r?.status !== 0 || !r?.data) throw new PlaudError(r?.msg || "Invalid Plaud 4.0 detail");
      this.detailCache.set(fid, r.data);
    }
    return this.detailCache.get(fid);
  }

  /** A short-lived download URL for the recording's audio (MP3 on classic accounts). */
  async audioUrl(id: string): Promise<string> {
    if (!this.v4) {
      const r = await this.data(`file/temp-url/${encodeURIComponent(id)}?is_opus=0`);
      if (r?.temp_url) return r.temp_url;
      if (!migrated(r)) throw new PlaudError(r?.msg || "Plaud gave no download link for this recording.");
      this.v4 = true;
    }
    const d = await this.v4Detail(id);
    const audio = (d.objects ?? []).find((o: any) => o.object_type === "AUDIO") ?? {};
    if (audio.content_url) return audio.content_url;
    if (audio.content_id) {
      const r = await this.data("file-app/v4/files/content/url", { method: "POST", body: JSON.stringify({ content_ids: [audio.content_id] }) });
      const url = r?.status === 0 ? r?.data?.url_map?.[audio.content_id] : null;
      if (url) return url;
    }
    throw new PlaudError("Plaud has no downloadable audio for this recording yet.");
  }

  /** Opens the audio as a stream (never buffered in the Worker) with its content type. */
  async audio(id: string): Promise<{ body: ReadableStream; contentType: string }> {
    const url = await this.audioUrl(id);
    const res = await fetch(url, { headers: { "User-Agent": UA } });
    if (!res.ok || !res.body) throw new PlaudError(`Couldn't download the audio (HTTP ${res.status}).`);
    const header = (res.headers.get("content-type") ?? "").split(";")[0].trim();
    const ext = new URL(url).pathname.split(".").pop()?.toLowerCase() ?? "";
    const byExt: Record<string, string> = { mp3: "audio/mpeg", m4a: "audio/mp4", mp4: "audio/mp4", ogg: "audio/ogg", opus: "audio/ogg", wav: "audio/wav", webm: "audio/webm" };
    const contentType = header.startsWith("audio/") ? header : byExt[ext] ?? "audio/mpeg";
    return { body: res.body, contentType };
  }

  private async fetchContent(link: string): Promise<any> {
    const res = await fetch(link, { headers: { "User-Agent": UA } });
    if (!res.ok) return null;
    const buf = new Uint8Array(await res.arrayBuffer());
    let text: string;
    if (buf[0] === 0x1f && buf[1] === 0x8b) {
      text = await new Response(new Blob([buf]).stream().pipeThrough(new DecompressionStream("gzip"))).text();
    } else {
      text = new TextDecoder().decode(buf);
    }
    try { return JSON.parse(text); } catch { return text; }
  }

  /** Plaud's own transcript (segments, seconds) and AI summary for one recording. */
  async content(id: string): Promise<{ segments: Segment[]; summary: string | null }> {
    type Item = { kind: "t" | "s"; primary: boolean; ready: boolean; link?: string; inline?: string };
    const items: Item[] = [];
    let legacy: any = null;
    if (!this.v4) {
      const r = await this.data(`file/detail/${encodeURIComponent(id)}`);
      if (migrated(r)) this.v4 = true;
      else legacy = r?.data ?? {};
    }
    if (this.v4) {
      const d = await this.v4Detail(id);
      const objs = (d.objects ?? []).filter((o: any) => o.object_type === "TRANSCRIPT" || o.object_type === "SUMMARY");
      const missing = objs.filter((o: any) => !o.content_url && o.content_id).map((o: any) => o.content_id);
      let urls: Record<string, string> = {};
      if (missing.length) {
        const r = await this.data("file-app/v4/files/content/url", { method: "POST", body: JSON.stringify({ content_ids: missing }) });
        urls = r?.status === 0 ? r?.data?.url_map ?? {} : {};
      }
      for (const o of objs) {
        items.push({ kind: o.object_type === "TRANSCRIPT" ? "t" : "s", primary: true, ready: o.task_status === 1, link: o.content_url || urls[o.content_id] });
      }
    } else {
      const inline: Record<string, string> = Object.fromEntries((legacy.pre_download_content_list ?? []).map((p: any) => [p.data_id, p.data_content]));
      for (const c of legacy.content_list ?? []) {
        const type = String(c.data_type ?? "").toLowerCase();
        const did = String(c.data_id ?? "");
        if (type === "transaction" || type === "transcript" || did.startsWith("source_transaction:")) {
          items.push({ kind: "t", primary: true, ready: c.task_status === 1, link: c.data_link, inline: inline[did] });
        } else if (["auto_sum_note", "sum_multi_note", "summary", "note", "ai_summary"].includes(type) || did.startsWith("auto_sum:") || did.startsWith("sum_multi:")) {
          const primary = type === "auto_sum_note" || did.startsWith("auto_sum:");
          items.push({ kind: "s", primary, ready: c.task_status === 1, link: c.data_link, inline: inline[did] });
        }
      }
    }
    const load = async (it?: Item) => {
      if (!it) return null;
      if (it.inline) { try { return JSON.parse(it.inline); } catch { return it.inline; } }
      return it.ready && it.link ? this.fetchContent(it.link) : null;
    };
    const rawT = await load(items.find((i) => i.kind === "t"));
    const rawS = await load(items.find((i) => i.kind === "s" && i.primary) ?? items.find((i) => i.kind === "s"));
    const arr: any[] = Array.isArray(rawT) ? rawT : rawT?.segments ?? rawT?.transcript ?? rawT?.data ?? [];
    const segments: Segment[] = arr.filter((s) => s && typeof s === "object").map((s) => ({
      start: (Number(s.start_time) || 0) / 1000,
      end: (Number(s.end_time) || 0) / 1000,
      text: String(s.content ?? s.text ?? "").trim(),
      speaker: typeof s.speaker === "number" ? `Speaker ${s.speaker}` : s.speaker ? String(s.speaker) : null,
    })).filter((s) => s.text);
    let summary: string | null = null;
    if (typeof rawS === "string") summary = rawS;
    else if (rawS && typeof rawS === "object") {
      summary = rawS.ai_content ?? rawS.summary ?? rawS.content ?? null;
      const points = rawS.key_points ?? rawS.highlights;
      const actions = rawS.action_items ?? rawS.todos;
      if (summary && Array.isArray(points) && points.length) summary += "\n\n## Key points\n" + points.map((p: any) => `- ${p}`).join("\n");
      if (summary && Array.isArray(actions) && actions.length) summary += "\n\n## Action items\n" + actions.map((p: any) => `- ${p}`).join("\n");
    }
    return { segments, summary: summary ? String(summary).trim() : null };
  }
}
