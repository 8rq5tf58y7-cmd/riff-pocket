/**
 * Speech-to-text for recordings Plaud hasn't transcribed.
 *
 *   workers-ai (default) — Deepgram Nova-3 on Cloudflare Workers AI: no extra account or key, speaker
 *                          labels. English. Falls back to Whisper large-v3-turbo (also Workers AI, no
 *                          speaker labels) when Nova-3 refuses the audio format, as it does Ogg Opus.
 *   openai               — any OpenAI-compatible /audio/transcriptions endpoint (OpenAI, Groq, …), your key.
 *   off                  — only use Plaud's own transcripts.
 */
import type { Segment } from "./plaud";

export interface TranscribeEnv {
  AI?: Ai;
  TRANSCRIBE_PROVIDER?: string;
  TRANSCRIBE_BASE_URL?: string;
  TRANSCRIBE_MODEL?: string;
  TRANSCRIBE_API_KEY?: string;
  /** BCP-47 hint, e.g. "en" or "en-US". Empty = detect. */
  TRANSCRIBE_LANGUAGE?: string;
}

export const NOVA3 = "@cf/deepgram/nova-3";

export function provider(env: TranscribeEnv): "workers-ai" | "openai" | "off" {
  const p = (env.TRANSCRIBE_PROVIDER || "workers-ai").toLowerCase();
  if (p === "off" || p === "none") return "off";
  if (p === "openai") return "openai";
  return env.AI ? "workers-ai" : "off";
}

export function engineLabel(env: TranscribeEnv): string {
  switch (provider(env)) {
    case "workers-ai": return "Workers AI · Deepgram Nova-3";
    case "openai": return `${env.TRANSCRIBE_MODEL || "whisper-1"} · ${new URL(env.TRANSCRIBE_BASE_URL || "https://api.openai.com/v1").host}`;
    default: return "off";
  }
}

export class TranscribeError extends Error {}

/** Deepgram response → segments: utterances if present, else words grouped by speaker, else one block. */
export function parseDeepgram(json: any): { segments: Segment[]; language: string | null } {
  const results = json?.results ?? json?.result?.results ?? json;
  const alt = results?.channels?.[0]?.alternatives?.[0];
  const language = results?.channels?.[0]?.detected_language ?? null;
  const label = (s: unknown) => (typeof s === "number" ? `Speaker ${s + 1}` : null);

  const utterances: any[] = results?.utterances ?? [];
  if (utterances.length) {
    return {
      language,
      segments: utterances
        .filter((u) => String(u.transcript ?? "").trim())
        .map((u) => ({ start: Number(u.start) || 0, end: Number(u.end) || 0, text: String(u.transcript).trim(), speaker: label(u.speaker) })),
    };
  }
  const words: any[] = alt?.words ?? [];
  if (words.length) {
    const segs: Segment[] = [];
    for (const w of words) {
      const text = String(w.punctuated_word ?? w.word ?? "");
      const speaker = label(w.speaker);
      const last = segs[segs.length - 1];
      const sentenceBreak = last && /[.?!]$/.test(last.text) && last.text.length > 160;
      if (last && last.speaker === speaker && Number(w.start) - last.end < 1.5 && !sentenceBreak) {
        last.text += " " + text;
        last.end = Number(w.end) || last.end;
      } else {
        segs.push({ start: Number(w.start) || 0, end: Number(w.end) || 0, text, speaker });
      }
    }
    return { segments: segs, language };
  }
  const text = String(alt?.transcript ?? "").trim();
  return { segments: text ? [{ start: 0, end: 0, text, speaker: null }] : [], language };
}

export const WHISPER = "@cf/openai/whisper-large-v3-turbo";
/** About 6 hours of Plaud's Ogg Opus; a Worker has 128 MB of memory. */
const MAX_AUDIO_BYTES = 90 * 1024 * 1024;

async function readAll(body: ReadableStream, max: number): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = body.getReader();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) { await reader.cancel(); throw new TranscribeError(`This recording is too large to transcribe here (over ${Math.round(max / 1048576)} MB).`); }
    chunks.push(value);
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.byteLength; }
  return out;
}

export function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

/** Workers AI Whisper response → segments (no speaker labels). */
export function parseWhisper(out: any): { segments: Segment[]; language: string | null } {
  const language = out?.transcription_info?.language ?? null;
  const segs: Segment[] = (Array.isArray(out?.segments) ? out.segments : [])
    .map((s: any) => ({ start: Number(s.start) || 0, end: Number(s.end) || 0, text: String(s.text ?? "").trim(), speaker: null }))
    .filter((s: Segment) => s.text);
  if (segs.length) return { segments: segs, language };
  const text = String(out?.text ?? "").trim();
  return { segments: text ? [{ start: 0, end: 0, text, speaker: null }] : [], language };
}

export async function transcribe(env: TranscribeEnv, audio: { body: ReadableStream; contentType: string }): Promise<{ segments: Segment[]; language: string | null; engine?: string }> {
  const mode = provider(env);
  if (mode === "off") throw new TranscribeError("Transcription is turned off (TRANSCRIBE_PROVIDER=off, or no Workers AI binding).");

  if (mode === "workers-ai") {
    // The whole file is read first: Nova-3 gets it with an exact length, and if Nova-3 refuses the
    // format (it rejects Plaud 4.0's Ogg Opus as "corrupt or unsupported"), Whisper gets the same bytes.
    const bytes = await readAll(audio.body, MAX_AUDIO_BYTES);
    const lang = env.TRANSCRIBE_LANGUAGE?.trim();
    const fixed = new FixedLengthStream(bytes.byteLength);
    const writer = fixed.writable.getWriter();
    void writer.write(bytes).then(() => writer.close());
    const res = (await env.AI!.run(NOVA3 as any, {
      audio: { body: fixed.readable, contentType: audio.contentType },
      diarize: true, punctuate: true, smart_format: true, utterances: true,
      ...(lang ? { language: lang } : { detect_language: true }),
    } as any, { returnRawResponse: true } as any)) as unknown as Response;
    if (res.ok) return { ...parseDeepgram(await res.json()), engine: "Workers AI · Deepgram Nova-3" };
    const novaError = (await res.text()).replace(/^.*?"message":"/s, "").replace(/\s*\([0-9a-f-]{20,}\).*$/s, "").slice(0, 160);
    try {
      const out = await env.AI!.run(WHISPER as any, { audio: base64(bytes), ...(lang ? { language: lang.slice(0, 2) } : {}) } as any);
      return { ...parseWhisper(out), engine: "Workers AI · Whisper large-v3-turbo (no speaker labels)" };
    } catch (e) {
      throw new TranscribeError(`Workers AI couldn't transcribe this audio. Nova-3 (HTTP ${res.status}): ${novaError}. Whisper: ${(e as Error).message.slice(0, 160)}`);
    }
  }

  // OpenAI-compatible Whisper (needs the whole file; most providers cap uploads at ~25 MB).
  const base = (env.TRANSCRIBE_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
  if (!env.TRANSCRIBE_API_KEY) throw new TranscribeError("Set TRANSCRIBE_API_KEY for the openai transcription provider.");
  const blob = await new Response(audio.body).blob();
  const form = new FormData();
  const ext = audio.contentType.includes("mp4") ? "m4a" : audio.contentType.includes("ogg") ? "ogg" : audio.contentType.includes("wav") ? "wav"
    : audio.contentType.includes("flac") ? "flac" : audio.contentType.includes("webm") ? "webm" : "mp3";
  form.append("file", new File([blob], `audio.${ext}`, { type: audio.contentType }));
  form.append("model", env.TRANSCRIBE_MODEL || "whisper-1");
  form.append("response_format", "verbose_json");
  form.append("timestamp_granularities[]", "segment");
  if (env.TRANSCRIBE_LANGUAGE) form.append("language", env.TRANSCRIBE_LANGUAGE.split("-")[0]);
  const res = await fetch(`${base}/audio/transcriptions`, { method: "POST", headers: { Authorization: `Bearer ${env.TRANSCRIBE_API_KEY}` }, body: form });
  if (!res.ok) throw new TranscribeError(`Transcription failed (HTTP ${res.status}): ${(await res.text()).slice(0, 200)}`);
  const j: any = await res.json();
  const segs: any[] = j.segments?.length ? j.segments : [{ start: 0, end: 0, text: j.text ?? "" }];
  return {
    language: j.language ?? null,
    segments: segs.map((s) => ({ start: Number(s.start) || 0, end: Number(s.end) || 0, text: String(s.text ?? "").trim(), speaker: null })).filter((s) => s.text),
  };
}
