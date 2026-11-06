/**
 * Speech-to-text for recordings Plaud hasn't transcribed.
 *
 *   workers-ai (default) — Deepgram Nova-3 on Cloudflare Workers AI: no extra account or key, speaker
 *                          labels, audio streamed straight from Plaud (never buffered). English.
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

export async function transcribe(env: TranscribeEnv, audio: { body: ReadableStream; contentType: string }): Promise<{ segments: Segment[]; language: string | null }> {
  const mode = provider(env);
  if (mode === "off") throw new TranscribeError("Transcription is turned off (TRANSCRIBE_PROVIDER=off, or no Workers AI binding).");

  if (mode === "workers-ai") {
    const lang = env.TRANSCRIBE_LANGUAGE?.trim();
    const res = (await env.AI!.run(NOVA3 as any, {
      audio: { body: audio.body, contentType: audio.contentType },
      diarize: true, punctuate: true, smart_format: true, utterances: true,
      ...(lang ? { language: lang } : { detect_language: true }),
    } as any, { returnRawResponse: true } as any)) as unknown as Response;
    if (!res.ok) throw new TranscribeError(`Workers AI couldn't transcribe this audio (HTTP ${res.status}): ${(await res.text()).slice(0, 200)}`);
    return parseDeepgram(await res.json());
  }

  // OpenAI-compatible Whisper (needs the whole file; most providers cap uploads at ~25 MB).
  const base = (env.TRANSCRIBE_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
  if (!env.TRANSCRIBE_API_KEY) throw new TranscribeError("Set TRANSCRIBE_API_KEY for the openai transcription provider.");
  const blob = await new Response(audio.body).blob();
  const form = new FormData();
  const ext = audio.contentType.includes("mp4") ? "m4a" : audio.contentType.includes("ogg") ? "ogg" : audio.contentType.includes("wav") ? "wav" : "mp3";
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
