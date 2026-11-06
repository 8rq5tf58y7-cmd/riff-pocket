# Plaud in Claude: the Riff Pocket connector

A small server you deploy once to your own **free Cloudflare account**. It connects your **Plaud account** to **Claude on claude.ai, the Claude desktop app and the Claude iPhone app**. Claude can then search, read and summarize your recordings. Turn on Claude's **Notion connector** next to it, and Claude can file them into Notion. No other app is needed.

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
| `plaud_recent_recordings`, `plaud_get_recording` | Live from Plaud |
| `list_folders` | Folders (only when you also use the Riff Pocket app's mirror) |

It also includes two ready-made prompts in Claude's **+** menu:
- **Save notes to Notion:** builds a "Recorded Notes" database with a Note ID on each page, so re-running never duplicates.
- **Weekly digest.**

Every tool is read-only, so Claude can't change or delete anything in Plaud.

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
# .dev.vars: OWNER_PASSWORD=…  SYNC_KEY=…  PLAUD_API_OVERRIDE=http://127.0.0.1:8790   (the last one is for tests only)
npx wrangler dev --local-protocol https --port 8788 --test-scheduled
NODE_TLS_REJECT_UNAUTHORIZED=0 BASE=https://127.0.0.1:8788 FAKE_PLAUD_PORT=8790 \
  OWNER_PASSWORD=… SYNC_KEY=… node test/e2e.mjs
```

The end-to-end test runs 20 checks. It plays Claude, the setup page and a fake Plaud server that has both the classic and the Plaud 4.0 API:
1. **Claude connecting:** OAuth discovery, dynamic registration, the password consent screen and a PKCE token exchange.
2. **Setup:** connecting Plaud with a token or an email code, then syncing gzip transcripts and summaries.
3. **Using it:** every tool and prompt, the cron handler, and refresh-token rotation.
