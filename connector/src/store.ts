/** D1 storage for the mirrored notes. */

export interface Segment { start: number; end: number; text: string; speaker?: string | null }
export interface Attachment { id: string; name: string; contentType?: string; size?: number; text?: string | null; deleted?: boolean }
export interface DeskNote {
  id: string;
  title: string;
  titleLocked?: boolean;
  createdAt: number;
  updatedAt: number;
  duration: number;
  source: string;
  plaudId?: string | null;
  folderId?: string | null;
  transcript?: { language?: string | null; segments: Segment[] } | null;
  transcriptSource?: string | null;
  summary?: string | null;
  summarySource?: string | null;
  summaryStyle?: unknown;
  summaryInstructions?: string | null;
  audioName?: string | null;
  hasAudio?: boolean;
  attachments?: Attachment[];
  deleted?: boolean;
}

export interface NoteRow {
  id: string;
  title: string;
  created_at: number;
  updated_at: number;
  duration: number;
  source: string | null;
  plaud_id: string | null;
  folder_id: string | null;
  folder_name?: string | null;
  summary: string | null;
  transcript_text: string | null;
  attachments_text: string | null;
}

export const clock = (s: number): string => {
  const t = Math.max(0, Math.floor(s || 0));
  return [Math.floor(t / 3600), Math.floor((t % 3600) / 60), t % 60].map((n) => String(n).padStart(2, "0")).join(":");
};

export function transcriptText(note: DeskNote): string {
  return (note.transcript?.segments ?? [])
    .filter((s) => (s.text ?? "").trim())
    .map((s) => `[${clock(s.start)}] ${s.speaker ? s.speaker + ": " : ""}${s.text.trim()}`)
    .join("\n");
}

export function attachmentsText(note: DeskNote): string {
  return (note.attachments ?? [])
    .filter((a) => !a.deleted && (a.text ?? "").trim())
    .map((a) => `### Attachment “${a.name}”\n${a.text}`)
    .join("\n\n");
}

export async function upsertNote(db: D1Database, note: DeskNote): Promise<void> {
  if (note.deleted) {
    await db.prepare("DELETE FROM notes WHERE id = ?").bind(note.id).run();
    return;
  }
  await db
    .prepare(
      `INSERT INTO notes (id, title, created_at, updated_at, duration, source, plaud_id, folder_id, summary, transcript_text, attachments_text, doc)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET title=excluded.title, created_at=excluded.created_at, updated_at=excluded.updated_at,
         duration=excluded.duration, source=excluded.source, plaud_id=excluded.plaud_id, folder_id=excluded.folder_id,
         summary=excluded.summary, transcript_text=excluded.transcript_text, attachments_text=excluded.attachments_text, doc=excluded.doc`,
    )
    .bind(
      note.id, note.title || "Recording", note.createdAt || 0, note.updatedAt || Date.now() / 1000, note.duration || 0,
      note.source ?? null, note.plaudId ?? null, note.folderId ?? null, note.summary ?? null,
      transcriptText(note) || null, attachmentsText(note) || null, JSON.stringify(note),
    )
    .run();
}

export async function pruneNotes(db: D1Database, keep: string[]): Promise<number> {
  const existing = await db.prepare("SELECT id FROM notes").all<{ id: string }>();
  const keepSet = new Set(keep);
  const gone = existing.results.filter((r) => !keepSet.has(r.id)).map((r) => r.id);
  for (let i = 0; i < gone.length; i += 50) {
    const chunk = gone.slice(i, i + 50);
    await db.prepare(`DELETE FROM notes WHERE id IN (${chunk.map(() => "?").join(",")})`).bind(...chunk).run();
  }
  return gone.length;
}

export async function upsertFolder(db: D1Database, f: { id: string; name: string; updatedAt?: number; deleted?: boolean }) {
  if (f.deleted) {
    await db.prepare("DELETE FROM folders WHERE id = ?").bind(f.id).run();
    return;
  }
  await db
    .prepare("INSERT INTO folders (id, name, updated_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at")
    .bind(f.id, (f.name || "Folder").slice(0, 80), f.updatedAt ?? Date.now() / 1000)
    .run();
}

export async function listFolders(db: D1Database) {
  return (
    await db
      .prepare("SELECT f.id, f.name, (SELECT COUNT(*) FROM notes n WHERE n.folder_id = f.id) AS count FROM folders f ORDER BY f.name COLLATE NOCASE")
      .all<{ id: string; name: string; count: number }>()
  ).results;
}

export async function getSetting<T>(db: D1Database, key: string): Promise<T | null> {
  const row = await db.prepare("SELECT value FROM settings WHERE key = ?").bind(key).first<{ value: string }>();
  return row ? (JSON.parse(row.value) as T) : null;
}

export async function setSetting(db: D1Database, key: string, value: unknown) {
  await db.prepare("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
    .bind(key, JSON.stringify(value)).run();
}

export async function getNote(db: D1Database, id: string): Promise<(NoteRow & { doc: string }) | null> {
  return await db
    .prepare("SELECT n.*, f.name AS folder_name FROM notes n LEFT JOIN folders f ON f.id = n.folder_id WHERE n.id = ?")
    .bind(id)
    .first<NoteRow & { doc: string }>();
}

const COLS = "n.id, n.title, n.created_at, n.updated_at, n.duration, n.source, n.plaud_id, n.folder_id, f.name AS folder_name, n.summary, n.transcript_text, n.attachments_text";

export interface Filters { folder?: string; since?: number; until?: number }

function where(filters: Filters, extra: string[] = [], args: unknown[] = []) {
  const clauses = [...extra];
  if (filters.folder) {
    if (filters.folder.toLowerCase() === "unfiled") clauses.push("n.folder_id IS NULL");
    else {
      clauses.push("LOWER(f.name) = LOWER(?)");
      args.push(filters.folder);
    }
  }
  if (filters.since !== undefined) { clauses.push("n.created_at >= ?"); args.push(filters.since); }
  if (filters.until !== undefined) { clauses.push("n.created_at < ?"); args.push(filters.until); }
  return { sql: clauses.length ? "WHERE " + clauses.join(" AND ") : "", args };
}

export async function recentNotes(db: D1Database, filters: Filters, limit: number): Promise<NoteRow[]> {
  const w = where(filters);
  return (
    await db.prepare(`SELECT ${COLS} FROM notes n LEFT JOIN folders f ON f.id = n.folder_id ${w.sql} ORDER BY n.created_at DESC LIMIT ?`)
      .bind(...w.args, limit).all<NoteRow>()
  ).results;
}

const STOP = new Set(["the", "and", "for", "are", "was", "were", "what", "when", "where", "who", "why", "how", "did", "does",
  "about", "with", "that", "this", "from", "have", "has", "had", "you", "your", "all", "any", "notes", "note", "recording"]);

export function terms(query: string): string[] {
  return Array.from(new Set((query.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'-]*/gu) ?? []).filter((t) => t.length > 1 && !STOP.has(t)))).slice(0, 8);
}

/** Keyword search across titles, summaries, transcripts and attachment text, best matches first. */
export async function searchNotes(db: D1Database, query: string, filters: Filters, limit: number) {
  const ts = terms(query);
  if (!ts.length) return (await recentNotes(db, filters, limit)).map((row) => ({ row, score: 0, snippet: snippetFor(row, []) }));
  const any = ts.map(() => "(LOWER(n.title) LIKE ? OR LOWER(n.summary) LIKE ? OR LOWER(n.transcript_text) LIKE ? OR LOWER(n.attachments_text) LIKE ?)");
  const likeArgs = ts.flatMap((t) => Array(4).fill(`%${t}%`));
  const w = where(filters, ["(" + any.join(" OR ") + ")"], likeArgs);
  const rows = (
    await db.prepare(`SELECT ${COLS} FROM notes n LEFT JOIN folders f ON f.id = n.folder_id ${w.sql} ORDER BY n.created_at DESC LIMIT 300`)
      .bind(...w.args).all<NoteRow>()
  ).results;
  const scored = rows.map((row) => {
    let score = 0;
    for (const t of ts) {
      if (row.title.toLowerCase().includes(t)) score += 5;
      if ((row.summary ?? "").toLowerCase().includes(t)) score += 3;
      if ((row.attachments_text ?? "").toLowerCase().includes(t)) score += 2;
      if ((row.transcript_text ?? "").toLowerCase().includes(t)) score += 1;
    }
    return { row, score, snippet: snippetFor(row, ts) };
  });
  scored.sort((a, b) => b.score - a.score || b.row.created_at - a.row.created_at);
  return scored.slice(0, limit);
}

export function snippetFor(row: NoteRow, ts: string[], width = 220): string {
  const sources = [row.transcript_text, row.summary, row.attachments_text].filter(Boolean) as string[];
  for (const text of sources) {
    const lower = text.toLowerCase();
    const hit = ts.map((t) => lower.indexOf(t)).filter((i) => i >= 0).sort((a, b) => a - b)[0];
    if (hit !== undefined) {
      const start = Math.max(0, hit - width / 2);
      return (start > 0 ? "…" : "") + text.slice(start, start + width).replace(/\s+/g, " ").trim() + "…";
    }
  }
  const lead = (row.summary ?? row.transcript_text ?? "").replace(/^#+\s*/gm, "").replace(/\s+/g, " ").trim();
  return lead ? lead.slice(0, width) + (lead.length > width ? "…" : "") : "";
}
