/**
 * Direct Plaud cloud access from the Worker (ported from Riffado's src/lib/plaud, AGPL-3.0, incl.
 * Plaud 4.0 support from riffado/riffado#328). Plaud sits behind Cloudflare bot protection and may
 * refuse requests from server IPs; callers turn PlaudBlocked into a friendly "use the mirror" hint.
 */

const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const MIGRATED = -1800907;
const VALID_HOST = /^https:\/\/([a-z0-9-]+\.)*plaud\.(ai|cn)$/;

export interface PlaudCreds { userToken: string; apiBase?: string; workspaceId?: string | null }
export interface PlaudRecording { id: string; title: string; startMs: number; durationMs: number }

export class PlaudError extends Error {}
export class PlaudBlocked extends PlaudError {}

const migrated = (b: any) => b?.status === MIGRATED || /migrated to 4\.0/i.test(String(b?.msg ?? ""));

export class Plaud {
  private base: string;
  private wt?: string;
  private v4 = false;
  private detailCache = new Map<string, any>();

  constructor(private creds: PlaudCreds) {
    this.base = (creds.apiBase || "https://api.plaud.ai").replace(/\/+$/, "");
    if (!VALID_HOST.test(this.base)) throw new PlaudError(`Not a Plaud API host: ${this.base}`);
  }

  private async call(path: string, bearer: string, init: RequestInit = {}): Promise<any> {
    const res = await fetch(`${this.base}/${path.replace(/^\//, "")}`, {
      ...init,
      headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json", "User-Agent": UA, Origin: "https://web.plaud.ai", Referer: "https://web.plaud.ai/" },
    });
    if (res.status === 401) throw new PlaudError("Plaud rejected the saved sign-in. Reconnect Plaud in Riff Pocket and send it to the connector again.");
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

  private async token(): Promise<string> {
    if (this.wt) return this.wt;
    try {
      let wid = this.creds.workspaceId;
      if (!wid) {
        const r = await this.call("team-app/workspaces/list?need_personal_workspace=true", this.creds.userToken);
        const spaces = r?.data?.workspaces ?? [];
        wid = (spaces.find((w: any) => w.workspace_type === "0") ?? spaces[0])?.workspace_id;
      }
      if (wid) {
        const r = await this.call(`user-app/auth/workspace/token/${encodeURIComponent(wid)}`, this.creds.userToken, { method: "POST", body: "{}" });
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

  async recent(limit = 20): Promise<PlaudRecording[]> {
    if (!this.v4) {
      const r = await this.data(`file/simple/web?skip=0&limit=${limit}&is_trash=0&sort_by=start_time&is_desc=true`);
      if (Array.isArray(r?.data_file_list)) {
        return r.data_file_list.map((f: any) => ({ id: f.id, title: f.filename || "Recording", startMs: f.start_time || 0, durationMs: f.duration || 0 }));
      }
      if (!migrated(r)) throw new PlaudError(r?.msg || "Couldn't list Plaud recordings");
      this.v4 = true;
    }
    const r = await this.data(`file-app/v4/recordings/all?sort_by=created&sort_order=desc&page_size=${Math.min(limit, 50)}`);
    if (r?.status !== 0 || !Array.isArray(r?.data?.items)) throw new PlaudError(r?.msg || "Invalid Plaud 4.0 listing");
    return r.data.items.filter((i: any) => i.file_id).map((i: any) => ({
      id: String(i.file_id).replace(/^of_/, ""), title: i.name || "Recording", startMs: i.created_at_show_ms || 0, durationMs: i.duration_ms || 0,
    }));
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

  private async fetchContent(link: string): Promise<any> {
    const res = await fetch(link, { headers: { "User-Agent": UA } });
    if (!res.ok || !res.body) return null;
    const buf = new Uint8Array(await res.arrayBuffer());
    let text: string;
    if (buf[0] === 0x1f && buf[1] === 0x8b) {
      const stream = new Blob([buf]).stream().pipeThrough(new DecompressionStream("gzip"));
      text = await new Response(stream).text();
    } else {
      text = new TextDecoder().decode(buf);
    }
    try { return JSON.parse(text); } catch { return text; }
  }

  /** Plaud's own transcript and summary for a recording. */
  async content(id: string): Promise<{ transcript: string | null; summary: string | null }> {
    type Item = { kind: "t" | "s"; ready: boolean; link?: string; inline?: any };
    const items: Item[] = [];
    let detail: any = null;
    if (!this.v4) {
      const r = await this.data(`file/detail/${encodeURIComponent(id)}`);
      if (migrated(r)) this.v4 = true;
      else detail = r?.data ?? {};
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
      for (const o of objs) items.push({ kind: o.object_type === "TRANSCRIPT" ? "t" : "s", ready: o.task_status === 1, link: o.content_url || urls[o.content_id] });
    } else {
      const inline: Record<string, string> = Object.fromEntries((detail.pre_download_content_list ?? []).map((p: any) => [p.data_id, p.data_content]));
      for (const c of detail.content_list ?? []) {
        const type = String(c.data_type ?? "").toLowerCase();
        const did = String(c.data_id ?? "");
        const kind = type === "transaction" || type === "transcript" || did.startsWith("source_transaction:") ? "t"
          : ["auto_sum_note", "sum_multi_note", "summary", "note", "ai_summary"].includes(type) || did.startsWith("auto_sum:") ? "s" : null;
        if (kind) items.push({ kind, ready: c.task_status === 1, link: c.data_link, inline: inline[did] });
      }
    }
    const load = async (it?: Item) => {
      if (!it) return null;
      if (it.inline) { try { return JSON.parse(it.inline); } catch { return it.inline; } }
      return it.ready && it.link ? this.fetchContent(it.link) : null;
    };
    const rawT = await load(items.find((i) => i.kind === "t"));
    const rawS = await load(items.find((i) => i.kind === "s"));
    const segs: any[] = Array.isArray(rawT) ? rawT : rawT?.segments ?? rawT?.transcript ?? rawT?.data ?? [];
    const transcript = segs.length
      ? segs.map((s) => {
          const t = Math.floor((s.start_time ?? 0) / 1000);
          const ts = [Math.floor(t / 3600), Math.floor((t % 3600) / 60), t % 60].map((n) => String(n).padStart(2, "0")).join(":");
          const who = typeof s.speaker === "number" ? `Speaker ${s.speaker}: ` : s.speaker ? `${s.speaker}: ` : "";
          return `[${ts}] ${who}${(s.content ?? s.text ?? "").trim()}`;
        }).join("\n")
      : null;
    const summary = typeof rawS === "string" ? rawS : rawS?.ai_content ?? rawS?.summary ?? rawS?.content ?? null;
    return { transcript, summary: summary ? String(summary).trim() : null };
  }
}
