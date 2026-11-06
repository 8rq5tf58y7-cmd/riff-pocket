# Riff Pocket connector: your notes in Claude

A small server you deploy once to your own **free Cloudflare account**. It lets **Claude on claude.ai, the Claude desktop app and the Claude iPhone app** search and read your recorded notes. Turn on Claude's **Notion connector** next to it, and Claude can file those notes into Notion.

```
Note Pro → Plaud app → Plaud cloud → Riff Pocket (iPhone) ── mirror ──▶ this connector ◀── Claude (web, desktop, iPhone)
                                                                                            └─▶ Notion connector
```

- **What it holds:** the iPhone app sends titles, AI summaries, transcripts, folders and the text of attached files. Audio stays on your phone.
- **Direct Plaud access (optional):** the connector can also read Plaud directly, for recordings not yet on your phone. Plaud protects its API with bot detection that may block Cloudflare's servers. If that happens, Claude says so and uses the mirrored notes instead.

## What Claude can do with it

| Tool | What it does |
|---|---|
| `search_notes` | Keyword search across titles, summaries, transcripts and attachments, filtered by folder and date range |
| `list_recent_notes` | "What did I record this week?" |
| `get_note` | Full note: summary, attachments' text, timestamped transcript |
| `list_folders` | Your folders and how many notes each holds |
| `plaud_recent_recordings`, `plaud_get_recording` | Straight from Plaud (optional, see above) |

It also includes two ready-made prompts:
- **Save notes to Notion:** builds a "Recorded Notes" database with a Note ID on each page, so re-running never duplicates.
- **Weekly digest.**

Every tool is read-only, so Claude can't change or delete your notes.

## Deploy, once (about 10 minutes)

You need a free [Cloudflare account](https://dash.cloudflare.com/sign-up) and [Node.js](https://nodejs.org) 20+. Run these from this `connector/` folder.

1. Install the tools:

   ```bash
   npm install
   npx wrangler login
   ```

2. Create the storage. Paste each printed `id` into `wrangler.jsonc`:

   ```bash
   npx wrangler kv namespace create OAUTH_KV
   npx wrangler d1 create riff-pocket
   npx wrangler d1 migrations apply DB --remote
   ```

3. Set two secrets. Never put them in a file.
   - **`OWNER_PASSWORD`:** the password you type when Claude connects. Use 12+ characters.
   - **`SYNC_KEY`:** the key your iPhone uses to send notes. Generate a long random one:

   ```bash
   node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
   npx wrangler secret put SYNC_KEY
   npx wrangler secret put OWNER_PASSWORD
   ```

4. Deploy:

   ```bash
   npx wrangler deploy
   ```

   It prints your address, like `https://riff-pocket-connector.<you>.workers.dev`. Open it in a browser to see the setup page.

## Connect your iPhone

In Riff Pocket, go to **Settings → Claude connector**:
1. Enter the address from step 4 and your `SYNC_KEY`, then tap **Connect**. Your notes upload, and stay updated after every sync, in the background, and whenever a note gets a new summary or title.
2. Optional: tap **Share Plaud sign-in with the connector** to let Claude reach Plaud directly.

## Add it to Claude

1. On [claude.ai](https://claude.ai), open **Customize → Connectors → Add custom connector**.
2. Paste the URL with `/mcp` on the end, for example `https://riff-pocket-connector.<you>.workers.dev/mcp`. Riff Pocket's settings has a **Copy connector URL** button.
3. Click **Connect**. A page asks for your connector password. Enter it and tap **Allow**.
4. It now also appears in the **Claude iPhone app** under the same account.

Try asking:
- "What did I decide about pricing last week?"
- "Save today's recordings to Notion." (turn on the Notion connector too, or use the *Save notes to Notion* prompt from the + menu)
- "Make a weekly digest of my Work folder."

## Security

- **Connecting Claude** uses OAuth 2.1 with PKCE, via [`@cloudflare/workers-oauth-provider`](https://github.com/cloudflare/workers-oauth-provider). Tokens are stored only as hashes. Each new connection needs your `OWNER_PASSWORD`. Wrong passwords are rate-limited: 8 tries per 15 minutes per IP.
- **The phone's sync API** needs `SYNC_KEY`. To revoke it, rotate the key with `npx wrangler secret put SYNC_KEY` and update the app.
- **Everything lives in your Cloudflare account:** the notes in D1, OAuth grants in KV, and the optional Plaud sign-in in D1. Nothing passes through the authors of this project.
- **Custom domain:** to keep the connector on one domain, set `PUBLIC_ORIGIN` (for example `https://notes.example.com`) as a variable. Requests for any other hostname are then refused.

## Develop and test

```bash
npm run db:local
npx wrangler dev --local-protocol https --port 8788
# in another terminal: OWNER_PASSWORD=… SYNC_KEY=… (from .dev.vars)
NODE_TLS_REJECT_UNAUTHORIZED=0 BASE=https://127.0.0.1:8788 node test/e2e.mjs
```

The end-to-end test plays both the iPhone app and Claude:
1. The iPhone side syncs notes.
2. Claude's side runs OAuth discovery, dynamic registration, the password consent screen and a PKCE token exchange.
3. It then calls every tool and prompt, and checks that the refresh token rotates.
