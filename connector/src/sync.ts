/** Pulls Plaud recordings (with Plaud's transcripts and AI summaries) into D1 so Claude's searches are instant. */
import { noteIdForPlaud } from "./ids";
import { oggStructure, Plaud, PlaudBlocked, plaudConnected, splitOgg, type PlaudCreds, type Segment } from "./plaud";
import { getNote, getSetting, setSetting, upsertNote, type DeskNote } from "./store";
import { engineLabel, provider, transcribe, transcribeBytes, transcribeUrl, type TranscribeEnv } from "./transcribe";

/** A Plaud client that saves renewed session tokens back to the database. */
export function openPlaud(env: { DB: D1Database; PLAUD_API_OVERRIDE?: string }, creds: PlaudCreds): Plaud {
  return new Plaud(creds, env.PLAUD_API_OVERRIDE, (c) => setSetting(env.DB, "plaud", c));
}

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
  if (!plaudConnected(creds)) {
    result.error = "Plaud isn't connected yet — open the connector's /setup page.";
    return result;
  }
  try {
    const plaud = openPlaud(env, creds!);
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
  // Count the attempt BEFORE starting: if the run is cut off (CPU, memory or time limits on a long
  // recording), the attempt still counts, so a recording can't be retried forever and burn the allowance.
  doc.transcribeAttempts = (doc.transcribeAttempts ?? 0) + 1;
  doc.transcribeError = "Started transcribing, but the run ended before it finished (the recording may be too long for Cloudflare's limits).";
  await upsertNote(env.DB, doc);
  let audioInfo = "";
  try {
    let result;
    if (provider(env) === "deepgram") {
      try {
        result = await transcribeUrl(env, await plaud.audioUrl(doc.plaudId!));
      } catch (e) {
        if (!/corrupt|unsupported/i.test((e as Error).message)) throw e;
        // Plaud 4.0 stores some long recordings as chained Ogg (several streams back to back), which
        // Deepgram rejects. Split it into its streams, transcribe each, and stitch the timelines.
        result = await transcribeChained(env, plaud, doc.plaudId!, (info) => { audioInfo = info; }, e as Error);
      }
    } else {
      const audio = await plaud.audio(doc.plaudId!);
      audioInfo = audio.info;
      result = await transcribe(env, audio);
    }
    const { segments, language, engine } = result;
    doc.transcript = { language, segments };
    doc.transcriptSource = engine ?? engineLabel(env);
    doc.transcribeError = segments.length ? null : "No speech found.";
    if (!segments.length) doc.transcribeAttempts = MAX_ATTEMPTS; // silent recording: don't retry
  } catch (e) {
    if (e instanceof PlaudBlocked) throw e;
    doc.transcribeError = (e as Error).message + (audioInfo ? ` [audio: ${audioInfo}]` : "");
  }
  doc.updatedAt = Date.now() / 1000;
  await upsertNote(env.DB, doc);
  return doc;
}

function isOpusStream(b: Uint8Array): boolean {
  const body = 27 + b[26];
  return String.fromCharCode(...b.subarray(body, body + 8)) === "OpusHead";
}

/** The codec header of one Ogg stream: codec id, channels, sample rate, mapping family, and the first audio packet's Opus TOC byte. */
function describeStream(b: Uint8Array): string {
  const nseg = b[26];
  const body = 27 + nseg;
  const id = String.fromCharCode(...b.subarray(body, body + 8)).replace(/[^\x20-\x7e]/g, ".");
  if (id !== "OpusHead") return `codec "${id}"`;
  const rate = (b[body + 12] | (b[body + 13] << 8) | (b[body + 14] << 16) | (b[body + 15] << 24)) >>> 0;
  // Third page = first audio page (after OpusHead and OpusTags pages) if those are one page each.
  let at = 0;
  for (let p = 0; p < 2 && at + 27 <= b.length; p++) {
    const n = b[at + 26]; let len = 0;
    for (let k = 0; k < n; k++) len += b[at + 27 + k];
    at += 27 + n + len;
  }
  const toc = at + 27 < b.length ? b[at + 27 + b[at + 26]] : undefined;
  return `Opus v${b[body + 8]}, ${b[body + 9]} ch, ${rate} Hz, mapping ${b[body + 18]}, first TOC ${toc?.toString(16) ?? "?"}`;
}

async function transcribeChained(env: SyncEnv, plaud: Plaud, plaudId: string, note: (info: string) => void, first: Error) {
  const audio = await plaud.audio(plaudId);
  const bytes = new Uint8Array(await new Response(audio.body).arrayBuffer());
  if (audio.contentType !== "audio/ogg") { note(`${audio.info}; ${bytes.length} bytes`); throw first; }
  const s = oggStructure(bytes);
  note(`Ogg, ${s.bytes} bytes: ${s.pages} pages, ${s.streams} stream(s)`
    + (s.badAt !== null ? `, structure breaks at byte ${s.badAt} (${Math.round((100 * s.badAt) / s.bytes)}% in)` : ", structure intact"));
  const all = splitOgg(bytes);
  note(`${s.bytes} bytes in ${all.length} Ogg stream(s): ` + all.map((p, i) => `#${i + 1} ${describeStream(p.bytes)}, ${Math.round(p.seconds)} s`).join("; "));
  // Plaud 4.0 files carry a "PLAUD.AI" data track (not audio) after the Opus audio: keep only audio.
  const parts = all.filter((p) => isOpusStream(p.bytes));
  if (!parts.length || (all.length === 1 && parts.length === 1)) throw first; // nothing different to send
  const segments: Segment[] = [];
  let offset = 0, language: string | null = null, engine = "";
  for (const [i, part] of parts.entries()) {
    let r;
    try {
      r = await transcribeBytes(env, part.bytes, "audio/ogg");
    } catch (e) {
      throw new Error(`Part ${i + 1} of ${parts.length}: ${(e as Error).message}`);
    }
    language ??= r.language;
    engine = parts.length > 1 ? `${r.engine} (${parts.length} parts)` : r.engine;
    // Deepgram numbers speakers per part, so "Speaker 1" in part 2 may be someone else: label by part.
    for (const seg of r.segments) {
      segments.push({ ...seg, start: seg.start + offset, end: seg.end + offset, speaker: seg.speaker && parts.length > 1 ? `${seg.speaker} (part ${i + 1})` : seg.speaker });
    }
    offset += part.seconds;
  }
  return { segments, language, engine };
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
