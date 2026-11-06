# Plaud in Claude: the Riff Pocket connector

A small server you deploy once to your own **free Cloudflare account**. It connects your **Plaud account** to **Claude on claude.ai, the Claude desktop app and the Claude iPhone app**:
- **Transcription:** recordings Plaud hasn't transcribed are transcribed by the connector, with speaker labels.
- **In Claude:** Claude can search, read and summarize all of your recordings.
- **Notion:** with Claude's **Notion connector** turned on next to it, Claude can file your recordings into Notion.

No other app is needed.

```
Plaud Note Pro → Plaud app → Plaud cloud ──(every 30 min)──▶ this connector ◀── Claude (web · desktop · iPhone)
                                                                                 └─▶ Notion connector
```

## What Claude can do with it

| Tool | What it does |
|---|---|
| `search_notes` | Keyword search across titles, Plaud's AI summaries and transcripts, filtered by folder and date range |
| `list_recent_notes` | "What did I record this week?" |
| `get_note` | One recording in full: summary and timestamped transcript with speakers |
| `sync_plaud` | Check Plaud for new recordings right now |
| `transcribe_recording` | Transcribe a recording Plaud didn't, right now |
| `plaud_recent_recordings`, `plaud_get_recording` | Live from Plaud |
| `list_folders` | Folders (only when you also use the Riff Pocket app's mirror) |

It also includes two ready-made prompts in Claude's **+** menu:
- **Save notes to Notion:** builds a "Recorded Notes" database with a Note ID on each page, so re-running never duplicates.
- **Weekly digest.**

Nothing in Plaud is ever changed or deleted. The only tool that writes is `transcribe_recording`, and it only saves a transcript in the connector.

## 1. Deploy (about 10 minutes, once)

You need a free [Cloudflare account](https://dash.cloudflare.com/sign-up) and [Node.js](https://nodejs.org) 20+. Run these from this `connector/` folder:

```bash
npm install
npx wrangler login                              # opens your browser to authorize
npx wrangler kv namespace create OAUTH_KV       # paste the printed id into wrangler.jsonc
npx wrangler d1 create riff-pocket              # paste the printed database_id into wrangler.jsonc
npx wrangler d1 migrations apply DB --remote
npx wrangler secret put OWNER_PASSWORD          # a password only you know (12+ characters)
npx wrangler deploy
```

`deploy` prints your address, like `https://riff-pocket-connector.<you>.workers.dev`.

## 2. Connect your Plaud account

Open **`https://riff-pocket-connector.<you>.workers.dev/setup`** in a browser on your computer.

- **If you signed up for Plaud with Apple or Google:**
  1. Drag the **Send Plaud to Claude** button to your bookmarks bar.
  2. Sign in at [web.plaud.ai](https://web.plaud.ai) as usual, then click the bookmark. It brings your Plaud sign-in back to the setup page.
  3. Enter your connector password and click **Connect Plaud**.
- **If you signed up with email:** enter your email, click **Email me a code**, then enter the code.

The connector imports your recent recordings, including Plaud's transcripts and AI summaries, then checks for new ones every 30 minutes. The setup page shows the sync status.

## 3. Add it to Claude

1. On [claude.ai](https://claude.ai), open **Customize → Connectors → Add custom connector**.
2. Paste `https://riff-pocket-connector.<you>.workers.dev/mcp`.
3. Click **Connect**, enter your connector password, and click **Allow**.
4. It now also appears in the **Claude iPhone app** under the same account.

Try asking:
- "What did I decide about pricing last week?"
- "Summarize today's meetings and list my action items."
- "Save this week's recordings to Notion." (turn on the Notion connector too, or use the *Save notes to Notion* prompt)

## Transcription

Plaud's own transcripts and summaries are used whenever they exist. When a recording has none, the connector transcribes it:
- **Automatically:** a few per 30-minute run.
- **On request:** say "transcribe my last recording" in Claude.

The audio streams from Plaud straight to the speech-to-text engine and is never stored by the connector.

| Engine | How | Cost |
|---|---|---|
| **Deepgram Nova-3 on Workers AI** (default) | Built into your Cloudflare account, with no key. Labels speakers. **English.** | About $0.005 per audio minute (≈ $0.31 per hour). The free Workers AI allowance covers roughly 20 minutes a day |
| **OpenAI-compatible Whisper** | Set `TRANSCRIBE_PROVIDER` to `openai` in `wrangler.jsonc`, plus `TRANSCRIBE_BASE_URL` and `TRANSCRIBE_MODEL` (for example Groq's `https://api.groq.com/openai/v1` with `whisper-large-v3-turbo`), and `npx wrangler secret put TRANSCRIBE_API_KEY`. Many languages. Uploads are capped at about 25 MB, which is roughly 25–50 minutes of audio | Your provider's price |
| Off | Set `TRANSCRIBE_PROVIDER` to `off`: Plaud's transcripts only | — |

Set `TRANSCRIBE_LANGUAGE` (for example `en`) to skip language detection.

**Long recordings and Cloudflare's free plan:** the free plan limits each run to 10 ms of CPU. Reading the speech-to-text result of a long recording can exceed that, so if transcriptions of long recordings fail, switch to [Workers Paid](https://developers.cloudflare.com/workers/platform/pricing/) ($5/month). The setup page and Claude show any failure, and each recording is retried up to 3 times.

## If Plaud blocks Cloudflare

Plaud protects its API with bot detection, and some server addresses are blocked; this is why Riffado offers residential proxies. If that happens to your connector, the setup page and Claude both say so plainly.

The fallback is to let the **Riff Pocket iPhone app** mirror your notes into the connector from your phone's own connection:
1. Run `npx wrangler secret put SYNC_KEY` (a long random value).
2. In the app, open Settings → Claude connector and enter the URL and that key.

Everything else stays the same.

## Security

- **Connecting Claude** uses OAuth 2.1 with PKCE, via [`@cloudflare/workers-oauth-provider`](https://github.com/cloudflare/workers-oauth-provider). Tokens are stored only as hashes.
- **Your password protects every connection.** Each new connection and every action on `/setup` needs your `OWNER_PASSWORD`. Wrong passwords are rate-limited to 8 tries per 15 minutes per IP.
- **The Plaud sign-in** is stored in your Cloudflare D1 database. **Disconnect Plaud** on `/setup` deletes it. Plaud sign-ins last about 300 days; reconnect when the setup page says so.
- **Your account only:** everything lives in your own Cloudflare account. Nothing passes through the authors of this project.
- **Custom domain:** to keep the connector on one domain, set `PUBLIC_ORIGIN` (for example `https://notes.example.com`) as a variable. Requests for any other hostname are then refused.

## Develop and test

```bash
npm run db:local
# .dev.vars: OWNER_PASSWORD=…  SYNC_KEY=…  PLAUD_API_OVERRIDE=http://127.0.0.1:8790  TRANSCRIBE_API_KEY=test-transcribe-key
# wrangler.test.jsonc = the same Worker without the Workers AI binding (which needs a Cloudflare login);
# transcription goes to a fake Whisper served by test/fake-plaud.mjs.
node test/unit.mjs
npm run dev:test
NODE_TLS_REJECT_UNAUTHORIZED=0 BASE=https://127.0.0.1:8788 FAKE_PLAUD_PORT=8790 \
  OWNER_PASSWORD=… SYNC_KEY=… node test/e2e.mjs
```

The end-to-end test runs 21 checks. It plays Claude, the setup page and a fake Plaud server that has both the classic and the Plaud 4.0 API:
1. **Claude connecting:** OAuth discovery, dynamic registration, the password consent screen and a PKCE token exchange.
2. **Setup:** connecting Plaud with a token or an email code, then syncing gzip transcripts and summaries, and transcribing what Plaud didn't.
3. **Using it:** every tool and prompt, the cron handler, and refresh-token rotation.
