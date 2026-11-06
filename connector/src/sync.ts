/** Pulls Plaud recordings (with Plaud's transcripts and AI summaries) into D1 so Claude's searches are instant. */
import { noteIdForPlaud } from "./ids";
import { Plaud, PlaudBlocked, type PlaudCreds } from "./plaud";
import { getNote, getSetting, setSetting, upsertNote, type DeskNote } from "./store";
import { engineLabel, provider, transcribe, type TranscribeEnv } from "./transcribe";

export interface SyncEnv extends TranscribeEnv { DB: D1Database; PLAUD_API_OVERRIDE?: string }

export interface SyncResult {
  at: number;
  listed: number;
  added: number;
  updated: number;
  /** Recordings still waiting for their transcript/summary (fetched on later runs). */
  pending: number;
  /** Recordings transcribed by the connector this run, and how many still wait for it. */
  transcribed?: number;
  toTranscribe?: number;
  blocked?: boolean;
  error?: string;
}

interface StoredDoc extends DeskNote {
  plaudVersion?: number;
  plaudContentFetched?: boolean;
  transcribeAttempts?: number;
  transcribeError?: string | null;
}

const MAX_ATTEMPTS = 3;

/**
 * @param contentBudget how many recordings' transcript/summary to fetch this run. Each costs ~2–4
 *   outgoing requests; the free Workers plan allows 50 per run, so the default stays well inside it.
 */
export async function syncPlaud(env: SyncEnv, contentBudget = 10, listLimit = 100, transcribeBudget = 0): Promise<SyncResult> {
  const result: SyncResult = { at: Date.now() / 1000, listed: 0, added: 0, updated: 0, pending: 0 };
  const creds = await getSetting<PlaudCreds>(env.DB, "plaud");
  if (!creds?.userToken) {
    result.error = "Plaud isn't connected yet — open the connector's /setup page.";
    return result;
  }
  try {
    const plaud = new Plaud(creds, env.PLAUD_API_OVERRIDE);
    const recs = await plaud.recent(listLimit);
    result.listed = recs.length;
    let budget = contentBudget;

    for (const rec of recs) {
      const id = noteIdForPlaud(rec.id);
      const row = await getNote(env.DB, id);
      const existing: StoredDoc | null = row ? JSON.parse(row.doc) : null;
      const changed = !existing || (existing.plaudVersion ?? 0) < rec.versionMs;
      const needsContent = !existing?.plaudContentFetched || changed;
      if (!changed && !needsContent) continue;

      const doc: StoredDoc = existing ?? {
        id, title: rec.title, createdAt: rec.startMs / 1000, updatedAt: Date.now() / 1000,
        duration: rec.durationMs / 1000, source: "plaud", plaudId: rec.id, attachments: [],
      };
      // Plaud's name wins unless someone renamed the note by hand (titleLocked comes from the phone mirror).
      if (!doc.titleLocked && rec.title) doc.title = rec.title;
      doc.duration = rec.durationMs / 1000 || doc.duration;
      doc.createdAt = rec.startMs / 1000 || doc.createdAt;
      doc.plaudId = rec.id;
      doc.updatedAt = Date.now() / 1000;

      const nothingToFetch = rec.hasTranscript === false && rec.hasSummary === false;
      if (needsContent && !nothingToFetch) {
        if (budget > 0) {
          budget--;
          const { segments, summary } = await plaud.content(rec.id);
          if (segments.length && (!doc.transcript?.segments?.length || doc.transcriptSource === "plaud")) {
            doc.transcript = { segments };
            doc.transcriptSource = "plaud";
          }
          // Keep a richer summary the phone already produced (different style/model).
          if (summary && (!doc.summary || doc.summarySource === "plaud")) {
            doc.summary = summary;
            doc.summarySource = "plaud";
          }
          doc.plaudContentFetched = true;
        } else {
          doc.plaudContentFetched = false;
          result.pending++;
        }
      } else if (nothingToFetch) {
        // Up to date for this version; Plaud bumps version_ms when it adds a transcript/summary.
        doc.plaudContentFetched = true;
      }
      doc.plaudVersion = doc.plaudContentFetched ? rec.versionMs : existing?.plaudVersion ?? 0;
      await upsertNote(env.DB, doc);
      existing ? result.updated++ : result.added++;
    }
    if (transcribeBudget > 0 && provider(env) !== "off") {
      const t = await transcribePending(env, plaud, transcribeBudget);
      result.transcribed = t.done;
      result.toTranscribe = t.remaining;
    } else if (provider(env) !== "off") {
      result.toTranscribe = (await untranscribed(env.DB)).length;
    }
  } catch (e) {
    result.blocked = e instanceof PlaudBlocked;
    result.error = (e as Error).message;
  }
  await setSetting(env.DB, "plaudSync", result);
  return result;
}

/** Plaud recordings with no transcript (Plaud's own was checked first), newest first. */
async function untranscribed(db: D1Database): Promise<{ id: string; doc: StoredDoc }[]> {
  const rows = (
    await db.prepare("SELECT id, doc FROM notes WHERE plaud_id IS NOT NULL AND (transcript_text IS NULL OR transcript_text = '') ORDER BY created_at DESC LIMIT 50")
      .all<{ id: string; doc: string }>()
  ).results;
  return rows
    .map((r) => ({ id: r.id, doc: JSON.parse(r.doc) as StoredDoc }))
    .filter((r) => r.doc.plaudContentFetched && (r.doc.transcribeAttempts ?? 0) < MAX_ATTEMPTS && r.doc.duration > 0);
}

/** Transcribes one recording with the connector's own engine and saves it. */
export async function transcribeNote(env: SyncEnv, plaud: Plaud, doc: StoredDoc): Promise<StoredDoc> {
  try {
    const { segments, language } = await transcribe(env, await plaud.audio(doc.plaudId!));
    doc.transcript = { language, segments };
    doc.transcriptSource = engineLabel(env);
    doc.transcribeError = segments.length ? null : "No speech found.";
    if (!segments.length) doc.transcribeAttempts = MAX_ATTEMPTS; // silent recording: don't retry
  } catch (e) {
    if (e instanceof PlaudBlocked) throw e;
    doc.transcribeAttempts = (doc.transcribeAttempts ?? 0) + 1;
    doc.transcribeError = (e as Error).message;
  }
  doc.updatedAt = Date.now() / 1000;
  await upsertNote(env.DB, doc);
  return doc;
}

export async function transcribePending(env: SyncEnv, plaud: Plaud, budget: number): Promise<{ done: number; remaining: number }> {
  const queue = await untranscribed(env.DB);
  let done = 0;
  for (const item of queue.slice(0, budget)) {
    const after = await transcribeNote(env, plaud, item.doc);
    if (after.transcript?.segments?.length) done++;
  }
  return { done, remaining: Math.max(0, queue.length - done) };
}
