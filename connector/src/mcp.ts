/**
 * Minimal MCP server over Streamable HTTP (JSON responses, stateless): initialize, tools, prompts.
 * Claude reaches it from claude.ai, the desktop app and the iPhone/Android apps.
 */
import { noteIdForPlaud } from "./ids";
import { Plaud, PlaudBlocked, PlaudError, type PlaudCreds } from "./plaud";
import { clock, getNote, getSetting, listFolders, recentNotes, searchNotes, type DeskNote, type NoteRow } from "./store";

export const SERVER_VERSION = "0.1.0";
const PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26"];
const MAX_RESULT = 140_000; // Claude's hosted limit is ~150k characters per tool result

const INSTRUCTIONS = `This connector gives you the user's recorded notes: Plaud Note Pro recordings (and phone recordings) mirrored from the Riff Pocket app, with AI titles, summaries, transcripts, folders and the text of attached files.
- Find notes with search_notes (keywords, folder, date range) or list_recent_notes, then read one with get_note.
- Cite note titles and [hh:mm:ss] timestamps when you answer.
- plaud_recent_recordings / plaud_get_recording read Plaud's cloud directly, for recordings not yet mirrored; they may be unavailable if Plaud blocks cloud servers.
- To save notes to Notion, use the Notion connector (if enabled) — see the save_to_notion prompt for the page layout.`;

type Json = Record<string, any>;
type Env = { DB: D1Database };

const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true };

const TOOLS = [
  {
    name: "search_notes",
    title: "Search notes",
    description: "Search the user's recorded notes by keywords across titles, summaries, transcripts and attached files. Optional folder (name or 'Unfiled') and date range (YYYY-MM-DD). Returns matching notes, newest relevant first, with ids for get_note.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Keywords, e.g. 'pricing Dana'. Empty lists recent notes." },
        folder: { type: "string", description: "Folder name, or 'Unfiled'." },
        from: { type: "string", description: "Earliest date, YYYY-MM-DD (inclusive)." },
        to: { type: "string", description: "Latest date, YYYY-MM-DD (inclusive)." },
        limit: { type: "integer", minimum: 1, maximum: 50, default: 10 },
      },
      additionalProperties: false,
    },
    annotations: { ...readOnly, openWorldHint: false },
  },
  {
    name: "list_recent_notes",
    title: "List recent notes",
    description: "List the user's most recent notes (title, date, duration, folder, summary preview). Use for 'what did I record today/this week'.",
    inputSchema: {
      type: "object",
      properties: {
        days: { type: "integer", minimum: 1, maximum: 365, description: "Only notes from the last N days." },
        folder: { type: "string", description: "Folder name, or 'Unfiled'." },
        limit: { type: "integer", minimum: 1, maximum: 50, default: 15 },
      },
      additionalProperties: false,
    },
    annotations: { ...readOnly, openWorldHint: false },
  },
  {
    name: "get_note",
    title: "Read a note",
    description: "Read one note in full: title, date, duration, folder, AI summary, attached files' text and the timestamped transcript.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Note id from search_notes or list_recent_notes." },
        include_transcript: { type: "boolean", default: true },
        max_transcript_chars: { type: "integer", minimum: 1000, maximum: 120000, default: 60000 },
      },
      required: ["id"],
      additionalProperties: false,
    },
    annotations: { ...readOnly, openWorldHint: false },
  },
  {
    name: "list_folders",
    title: "List folders",
    description: "List the user's note folders with how many notes each holds.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { ...readOnly, openWorldHint: false },
  },
  {
    name: "plaud_recent_recordings",
    title: "Plaud: recent recordings",
    description: "List recent recordings straight from the user's Plaud cloud account (including ones not yet mirrored as notes). May be unavailable if Plaud blocks cloud servers.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 50, default: 20 } },
      additionalProperties: false,
    },
    annotations: { ...readOnly, openWorldHint: true },
  },
  {
    name: "plaud_get_recording",
    title: "Plaud: transcript & summary",
    description: "Read Plaud's own transcript and summary for one recording straight from the Plaud cloud. Prefer get_note when the recording is already mirrored.",
    inputSchema: {
      type: "object",
      properties: { plaud_id: { type: "string", description: "Recording id from plaud_recent_recordings." } },
      required: ["plaud_id"],
      additionalProperties: false,
    },
    annotations: { ...readOnly, openWorldHint: true },
  },
];

const PROMPTS = [
  {
    name: "save_to_notion",
    title: "Save notes to Notion",
    description: "Copy recorded notes into a Notion database (uses the Notion connector).",
    arguments: [
      { name: "which", description: "Which notes, e.g. 'today', 'this week', 'folder Work', or a search", required: false },
      { name: "database", description: "Notion database or page to save into (default: 'Recorded Notes')", required: false },
    ],
  },
  {
    name: "weekly_digest",
    title: "Weekly digest",
    description: "Summarize the past week's recordings: decisions, action items, open questions.",
    arguments: [{ name: "folder", description: "Limit to one folder", required: false }],
  },
];

function promptMessages(name: string, args: Json): Json[] {
  if (name === "save_to_notion") {
    const which = args.which || "this week";
    const db = args.database || "Recorded Notes";
    return [{
      role: "user",
      content: {
        type: "text",
        text: `Save my recorded notes (${which}) to Notion.

1. Find them with search_notes or list_recent_notes, then read each with get_note (include_transcript: true).
2. With the Notion connector, find the database "${db}" (create it if it doesn't exist, with properties: Name (title), Date (date), Duration (text), Folder (select), Source (select), Note ID (text)).
3. Before creating a page, search Notion for the Note ID so you never add a duplicate; update the existing page instead.
4. For each note create a page: properties from the note; body = the AI summary as Markdown (headings and bullets), then a "Files" section listing attached file names, then the full transcript inside a toggle block titled "Transcript".
5. Finish with a short table of what you created or updated, with links.`,
      },
    }];
  }
  const folder = args.folder ? ` in the folder "${args.folder}"` : "";
  return [{
    role: "user",
    content: {
      type: "text",
      text: `Using list_recent_notes (days: 7${args.folder ? `, folder: "${args.folder}"` : ""}) and get_note, write a digest of my recordings from the past week${folder}: a few sentences on themes, then sections for Decisions, Action items (owner — task — due), and Open questions. Cite note titles and [timestamps].`,
    },
  }];
}

// ---------------------------------------------------------------- tool implementations

const day = (s?: string, end = false): number | undefined => {
  if (!s) return undefined;
  const t = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(s) ? s + "T00:00:00Z" : s);
  if (Number.isNaN(t)) throw new ToolError(`Invalid date "${s}" — use YYYY-MM-DD.`);
  return t / 1000 + (end ? 86_400 : 0);
};
const fmtDate = (sec: number) => new Date(sec * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
const fmtDur = (sec: number) => {
  const m = Math.round((sec || 0) / 60);
  return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`;
};

class ToolError extends Error {}

function noteLine(row: NoteRow, snippet?: string): string {
  const meta = [fmtDate(row.created_at), fmtDur(row.duration), row.folder_name ? `📁 ${row.folder_name}` : null, row.plaud_id ? "Plaud" : row.source]
    .filter(Boolean).join(" · ");
  return `- **${row.title}** — ${meta}\n  id: \`${row.id}\`${snippet ? `\n  ${snippet}` : ""}`;
}

function preview(row: NoteRow): string {
  const s = (row.summary ?? "").split("\n").map((l) => l.replace(/^[#\-*•\d.\s]+/, "").replace(/\*\*/g, "").trim())
    .filter((l) => l && !/^(summary|overview|tl;dr)$/i.test(l)).slice(0, 2).join(" · ");
  return s ? s.slice(0, 240) : "";
}

async function plaudClient(env: Env): Promise<Plaud> {
  const creds = await getSetting<PlaudCreds>(env.DB, "plaud");
  if (!creds?.userToken) {
    throw new ToolError("Plaud isn't connected to this connector yet. In Riff Pocket: Settings → Claude connector → Share Plaud sign-in. Mirrored notes (search_notes) work without it.");
  }
  return new Plaud(creds);
}

async function callTool(env: Env, name: string, a: Json): Promise<string> {
  switch (name) {
    case "search_notes": {
      const limit = Math.min(Math.max(Number(a.limit) || 10, 1), 50);
      const hits = await searchNotes(env.DB, String(a.query ?? ""), { folder: a.folder, since: day(a.from), until: day(a.to, true) }, limit);
      if (!hits.length) return "No matching notes. Try fewer or different keywords, or list_recent_notes.";
      return `${hits.length} note${hits.length === 1 ? "" : "s"}:\n\n` + hits.map((h) => noteLine(h.row, h.snippet)).join("\n");
    }
    case "list_recent_notes": {
      const limit = Math.min(Math.max(Number(a.limit) || 15, 1), 50);
      const since = a.days ? Date.now() / 1000 - Number(a.days) * 86_400 : undefined;
      const rows = await recentNotes(env.DB, { folder: a.folder, since }, limit);
      if (!rows.length) return "No notes yet. Notes appear after Riff Pocket on the iPhone syncs to this connector.";
      return rows.map((r) => noteLine(r, preview(r))).join("\n");
    }
    case "get_note": {
      const row = await getNote(env.DB, String(a.id ?? ""));
      if (!row) throw new ToolError(`No note with id ${a.id}. Use search_notes to find ids.`);
      const doc = JSON.parse(row.doc) as DeskNote;
      const parts = [
        `# ${row.title}`,
        `${fmtDate(row.created_at)} · ${fmtDur(row.duration)}${row.folder_name ? ` · 📁 ${row.folder_name}` : ""} · source: ${row.plaud_id ? "Plaud" : row.source}${row.plaud_id ? ` (Plaud id ${row.plaud_id})` : ""}`,
        `Note ID: ${row.id}`,
        "",
        "## Summary",
        row.summary?.trim() || "_No summary yet._",
      ];
      const atts = (doc.attachments ?? []).filter((x) => !x.deleted);
      if (atts.length) {
        parts.push("", "## Attached files");
        for (const x of atts) parts.push(`### ${x.name}`, x.text ? x.text.slice(0, 20_000) : "_(no readable text)_");
      }
      if (a.include_transcript !== false) {
        const max = Math.min(Math.max(Number(a.max_transcript_chars) || 60_000, 1_000), 120_000);
        const t = row.transcript_text ?? "";
        parts.push("", "## Transcript", t ? (t.length > max ? t.slice(0, max) + `\n… (truncated; ${t.length - max} more characters)` : t) : "_No transcript yet._");
      }
      return parts.join("\n");
    }
    case "list_folders": {
      const folders = await listFolders(env.DB);
      return folders.length ? folders.map((f) => `- ${f.name} (${f.count})`).join("\n") : "No folders yet.";
    }
    case "plaud_recent_recordings": {
      const plaud = await plaudClient(env);
      const recs = await plaud.recent(Math.min(Math.max(Number(a.limit) || 20, 1), 50));
      const lines = await Promise.all(recs.map(async (r) => {
        const mirrored = await getNote(env.DB, noteIdForPlaud(r.id));
        return `- **${r.title}** — ${fmtDate(r.startMs / 1000)} · ${fmtDur(r.durationMs / 1000)}\n  plaud_id: \`${r.id}\`${mirrored ? ` · mirrored as note \`${mirrored.id}\` (use get_note)` : ""}`;
      }));
      return lines.join("\n") || "No recordings in Plaud.";
    }
    case "plaud_get_recording": {
      const id = String(a.plaud_id ?? "");
      const mirrored = await getNote(env.DB, noteIdForPlaud(id));
      const plaud = await plaudClient(env);
      const { transcript, summary } = await plaud.content(id);
      return [
        mirrored ? `(Also mirrored as note \`${mirrored.id}\` — get_note includes Riff Pocket's own summary and attachments.)\n` : "",
        "## Plaud summary", summary || "_Plaud hasn't summarized this recording._",
        "", "## Plaud transcript", transcript ? transcript.slice(0, 110_000) : "_Plaud hasn't transcribed this recording._",
      ].join("\n");
    }
  }
  throw new ToolError(`Unknown tool ${name}`);
}

// ---------------------------------------------------------------- JSON-RPC

async function handle(env: Env, msg: Json): Promise<Json | null> {
  const { id, method, params = {} } = msg ?? {};
  const isNotification = id === undefined || id === null;
  const ok = (result: Json) => ({ jsonrpc: "2.0", id, result });
  const fail = (code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });
  if (msg?.jsonrpc !== "2.0" || typeof method !== "string") return isNotification ? null : fail(-32600, "Invalid request");
  if (isNotification) return null; // notifications/initialized, cancelled, …

  switch (method) {
    case "initialize": {
      const requested = String(params.protocolVersion ?? "");
      return ok({
        protocolVersion: PROTOCOLS.includes(requested) ? requested : PROTOCOLS[0],
        capabilities: { tools: { listChanged: false }, prompts: { listChanged: false } },
        serverInfo: { name: "riff-pocket", title: "Riff Pocket notes", version: SERVER_VERSION },
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return ok({});
    case "tools/list":
      return ok({ tools: TOOLS });
    case "prompts/list":
      return ok({ prompts: PROMPTS });
    case "prompts/get": {
      const p = PROMPTS.find((x) => x.name === params.name);
      if (!p) return fail(-32602, `Unknown prompt ${params.name}`);
      return ok({ description: p.description, messages: promptMessages(p.name, params.arguments ?? {}) });
    }
    case "resources/list":
      return ok({ resources: [] });
    case "tools/call": {
      if (!TOOLS.some((t) => t.name === params.name)) return fail(-32602, `Unknown tool ${params.name}`);
      try {
        let text = await callTool(env, params.name, params.arguments ?? {});
        if (text.length > MAX_RESULT) text = text.slice(0, MAX_RESULT) + "\n… (truncated to fit Claude's limit)";
        return ok({ content: [{ type: "text", text }] });
      } catch (e) {
        const message = e instanceof PlaudBlocked
          ? `${e.message} Use search_notes / get_note instead — Riff Pocket mirrors your Plaud notes here from your phone.`
          : e instanceof ToolError || e instanceof PlaudError
            ? e.message
            : `Something went wrong: ${(e as Error).message}`;
        return ok({ content: [{ type: "text", text: message }], isError: true });
      }
    }
    default:
      return fail(-32601, `Method not found: ${method}`);
  }
}

/** POST /mcp — JSON-RPC message or batch; GET/DELETE not offered (no server-initiated stream, stateless). */
export async function mcpFetch(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: { Allow: "POST" } });
  }
  let body: any;
  try {
    body = await request.json();
  } catch {
    return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, { status: 400 });
  }
  const messages = Array.isArray(body) ? body : [body];
  const replies = (await Promise.all(messages.map((m) => handle(env, m)))).filter(Boolean);
  if (!replies.length) return new Response(null, { status: 202 });
  return Response.json(Array.isArray(body) ? replies : replies[0]);
}

export { clock };
