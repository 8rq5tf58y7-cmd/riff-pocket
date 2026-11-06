// Unit tests for pure helpers (Node strips the TypeScript types).
import assert from "node:assert/strict";
import { parseDeepgram, provider, engineLabel } from "../src/transcribe.ts";
import { cleanUserToken, jwtClaims } from "../src/plaud.ts";

// Deepgram (Workers AI Nova-3) with utterances + diarization
const withUtterances = {
  results: {
    channels: [{ detected_language: "en", alternatives: [{ transcript: "Hello there. Hi Dana.", words: [] }] }],
    utterances: [
      { start: 0.08, end: 1.2, transcript: "Hello there.", speaker: 0 },
      { start: 1.5, end: 2.4, transcript: "Hi Dana.", speaker: 1 },
      { start: 2.5, end: 2.6, transcript: "  ", speaker: 1 },
    ],
  },
};
let r = parseDeepgram(withUtterances);
assert.equal(r.language, "en");
assert.deepEqual(r.segments.map((s) => [s.speaker, s.text]), [["Speaker 1", "Hello there."], ["Speaker 2", "Hi Dana."]]);

// Words only: grouped by speaker and pauses
const wordsOnly = { results: { channels: [{ alternatives: [{ words: [
  { word: "we", punctuated_word: "We", start: 0, end: 0.2, speaker: 0 },
  { word: "ship", punctuated_word: "ship.", start: 0.3, end: 0.6, speaker: 0 },
  { word: "great", punctuated_word: "Great!", start: 0.9, end: 1.1, speaker: 1 },
  { word: "later", punctuated_word: "Later", start: 5, end: 5.3, speaker: 1 },
] }] }] } };
r = parseDeepgram(wordsOnly);
assert.deepEqual(r.segments.map((s) => s.text), ["We ship.", "Great!", "Later"]);
assert.equal(r.segments[1].speaker, "Speaker 2");

// Transcript only, and empty
assert.equal(parseDeepgram({ results: { channels: [{ alternatives: [{ transcript: "Just text" }] }] } }).segments[0].text, "Just text");
assert.equal(parseDeepgram({}).segments.length, 0);

// Provider selection
assert.equal(provider({ AI: {} }), "workers-ai");
assert.equal(provider({}), "off"); // no binding, no override
assert.equal(provider({ AI: {}, TRANSCRIBE_PROVIDER: "off" }), "off");
assert.equal(provider({ TRANSCRIBE_PROVIDER: "openai" }), "openai");
assert.match(engineLabel({ AI: {} }), /Nova-3/);

// Token cleaning
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const ut = `${b64({ alg: "HS256" })}.${b64({ sub: "u", exp: Math.floor(Date.now() / 1000) + 1000 })}.s`;
assert.equal(cleanUserToken(`  Bearer "${ut}" `), ut);
assert.equal(jwtClaims(ut).sub, "u");
assert.throws(() => cleanUserToken(`${b64({ alg: "HS256" })}.${b64({ wid: "W" })}.s`), /workspace token/);
assert.throws(() => cleanUserToken("nope"), /doesn't look like/);

console.log("unit tests passed");
