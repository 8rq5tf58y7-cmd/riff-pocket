/** HTML pages: the consent screen and the landing page, in Riff Pocket's warm palette. */

export const esc = (v: unknown) => String(v ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const STYLE = `
:root{--bg:#FAF9F5;--surface:#F0EEE6;--raised:#fff;--border:#E3E0D6;--text:#1F1E1D;--muted:#75736B;--accent:#C96442;--danger:#B3402A}
@media (prefers-color-scheme:dark){:root{--bg:#262624;--surface:#30302E;--raised:#393937;--border:#4A4945;--text:#F4F3EE;--muted:#A9A69C;--accent:#D97757;--danger:#E07A66}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,"Segoe UI",system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;padding:20px}
.card{width:min(460px,100%);background:var(--surface);border:1px solid var(--border);border-radius:22px;padding:28px}
h1{font-family:"Iowan Old Style",Palatino,Georgia,serif;font-weight:500;font-size:26px;margin:.2em 0 .4em}
.spark{color:var(--accent);font-weight:700;font-size:28px}.muted{color:var(--muted);font-size:14px}
code{font-family:ui-monospace,"Cascadia Code",Consolas,monospace;font-size:13px;background:var(--raised);padding:2px 6px;border-radius:6px;word-break:break-all}
input{width:100%;font:inherit;padding:11px 13px;border-radius:12px;border:1px solid var(--border);background:var(--raised);color:var(--text);margin:6px 0 14px}
.row{display:flex;gap:10px}button{flex:1;font:inherit;font-weight:600;border:0;border-radius:999px;padding:11px;cursor:pointer}
.allow{background:var(--accent);color:#fff}.deny{background:var(--raised);color:var(--text);border:1px solid var(--border)}
.err{color:var(--danger);font-weight:600}.warn{background:var(--raised);border-radius:12px;padding:10px 12px;font-size:14px}
ul{padding-left:20px}li{margin:4px 0}`;

const page = (title: string, body: string) =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title><style>${STYLE}</style></head><body><main class="card">${body}</main></body></html>`;

export interface ConsentView {
  clientName: string;
  clientDomain?: string;
  redirectHost: string;
  redirectIsLoopback: boolean;
  handle: string;
  error?: string;
}

export function consentPage(v: ConsentView): string {
  const who = v.clientDomain
    ? `Published by <strong>${esc(v.clientDomain)}</strong>.`
    : "This app registered itself, so its name isn't verified.";
  return page(`Allow ${v.clientName}?`, `
    <div class="spark">✻</div>
    <h1>Allow ${esc(v.clientName)} to read your notes?</h1>
    <p class="muted">${who} Access goes to <strong>${esc(v.redirectHost)}</strong>.</p>
    ${v.redirectIsLoopback ? `<p class="warn"><strong>This sends access to an app on a computer.</strong> Continue only if you just started connecting from it.</p>` : ""}
    <p>It will be able to search and read your recorded notes — titles, summaries, transcripts, folders and attached files' text — and your recent Plaud recordings. It can't change or delete anything.</p>
    ${v.error ? `<p class="err">${esc(v.error)}</p>` : ""}
    <form method="post">
      <input type="hidden" name="handle" value="${esc(v.handle)}">
      <label class="muted" for="pw">Connector password (the OWNER_PASSWORD you set)</label>
      <input id="pw" name="password" type="password" autocomplete="current-password" autofocus>
      <div class="row">
        <button class="deny" name="decision" value="deny">Deny</button>
        <button class="allow" name="decision" value="approve">Allow</button>
      </div>
    </form>`);
}

export function messagePage(title: string, message: string, status = 400): Response {
  return new Response(page(title, `<div class="spark">✻</div><h1>${esc(title)}</h1><p>${esc(message)}</p>`), {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "X-Frame-Options": "DENY" },
  });
}

export function landingPage(origin: string, notes: number, plaudConnected: boolean): Response {
  return new Response(page("Riff Pocket connector", `
    <div class="spark">✻</div>
    <h1>Riff Pocket connector</h1>
    <p>Your recorded notes in Claude — on claude.ai, the desktop app and the Claude iPhone app.</p>
    <p class="muted">${notes} note${notes === 1 ? "" : "s"} mirrored · Plaud ${plaudConnected ? "connected" : "not connected"}</p>
    <ol>
      <li>In Claude: <strong>Customize → Connectors → Add custom connector</strong>.</li>
      <li>URL: <code>${esc(origin)}/mcp</code></li>
      <li>Click <strong>Connect</strong> and enter your connector password.</li>
      <li>On iPhone, it appears automatically in the Claude app.</li>
    </ol>
    <p class="muted">Phone sync URL for Riff Pocket: <code>${esc(origin)}</code></p>`), {
    headers: { "Content-Type": "text/html; charset=utf-8", "X-Frame-Options": "DENY" },
  });
}
