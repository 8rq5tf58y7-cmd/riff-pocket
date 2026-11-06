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

export interface SetupView {
  origin: string;
  nonce: string;
  notes: number;
  plaud: { connected: boolean; apiBase?: string; expires?: number | null; session?: boolean };
  sync?: { at: number; listed: number; added: number; updated: number; pending: number; transcribed?: number; toTranscribe?: number; blocked?: boolean; error?: string } | null;
  transcription: string;
  message?: { text: string; ok: boolean };
  /** After "send code": the second email step. */
  otp?: { otpToken: string; apiBase: string; email: string };
}

/**
 * The "Send Plaud to Claude" bookmarklet, run on web.plaud.ai. Plaud has moved where
 * its web app keeps the sign-in, so instead of one fixed key it looks for any JWT in
 * localStorage, sessionStorage and readable cookies (also inside JSON values), skips
 * workspace tokens, and prefers pld_tokenstr, then a key named like a token, then the
 * longest-lived one. When there is none it lists the key names (never values).
 * No backslashes or newlines: it travels inside a javascript: URL.
 */
export function bookmarkletSource(origin: string): string {
  return `(()=>{` +
    // Plaud 4.0 web session (Sept 2026+): current workspace, its API domain, and its token pair.
    `try{const w=JSON.parse(localStorage.getItem('pld_session.workspace')||'null');const id=w&&w.currentId;` +
    `const tk=JSON.parse(localStorage.getItem('pld_session.tokens')||'null');const e=id&&tk&&tk.byWsId&&tk.byWsId[id];` +
    `if(e&&e.token&&e.refreshToken){let d=null;const l=w.list||{};for(const k in l){const x=l[k];if(x&&x.workspaceId===id&&x.domain)d=x.domain}` +
    `const S={workspaceId:id,domain:d,token:e.token,refreshToken:e.refreshToken,deviceId:String(localStorage.getItem('pld_DEVICE_ID')||'').replace(/^"|"$/g,'')};` +
    `location.href=${JSON.stringify(origin + "/setup#session=")}+encodeURIComponent(JSON.stringify(S))+'&from=pld_session';return}}catch(err){}` +
    `const J=/eyJ[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+/g;` +
    `const C=t=>{try{return JSON.parse(atob(t.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')))}catch(e){return null}};` +
    `const F=[];const add=(k,v)=>((v||'').match(J)||[]).forEach(t=>F.push({k,t,c:C(t)}));` +
    `for(const s of [localStorage,sessionStorage]){for(let i=0;i<s.length;i++){const k=s.key(i);add(k,s.getItem(k))}}` +
    `document.cookie.split(';').forEach(p=>{const i=p.indexOf('=');add(p.slice(0,i).trim(),decodeURIComponent(p.slice(i+1)))});` +
    `const ok=F.filter(f=>f.c&&typeof f.c.exp==='number'&&!f.c.wid&&!f.c.ut_ref);` +
    `const p=ok.find(f=>/pld_tokenstr|pld_ut/i.test(f.k))||ok.filter(f=>/token/i.test(f.k)).sort((a,b)=>(b.c.exp||0)-(a.c.exp||0))[0]||ok.sort((a,b)=>(b.c.exp||0)-(a.c.exp||0))[0];` +
    `if(!p){alert('No Plaud sign-in this button can read on '+location.host+'. Plaud may keep it in a protected cookie: use the Copy it from Firefox or Chrome steps on the setup page instead. Saved names here: '+[...Object.keys(localStorage),...Object.keys(sessionStorage),...document.cookie.split(';').map(c=>c.split('=')[0].trim())].filter(Boolean).join(', ').slice(0,700));return}` +
    `location.href=${JSON.stringify(origin + "/setup#token=")}+encodeURIComponent(p.t)+'&from='+encodeURIComponent(p.k)})()`;
}

export function setupPage(v: SetupView): Response {
  const when = (s: number) => new Date(s * 1000).toUTCString().replace(" GMT", " UTC");
  const bookmarklet = "javascript:" + bookmarkletSource(v.origin);
  const sync = v.sync;
  const status = !v.plaud.connected
    ? `<p class="warn">Plaud isn't connected yet.</p>`
    : `<p>✓ Plaud connected · ${esc(v.plaud.apiBase ?? "")}${v.plaud.expires ? ` · sign-in valid until ${esc(when(v.plaud.expires).slice(5, 16))}` : ""}</p>
       ${sync ? `<p class="muted">Last sync ${esc(when(sync.at))}: ${sync.listed} recordings seen, ${sync.added} new, ${sync.updated} updated${sync.pending ? `, ${sync.pending} still loading (next runs)` : ""}${sync.transcribed ? `, ${sync.transcribed} transcribed` : ""}${sync.toTranscribe ? `, ${sync.toTranscribe} waiting for transcription` : ""}.</p>` : ""}
       <p class="muted">Transcription for recordings Plaud didn't transcribe: <strong>${esc(v.transcription)}</strong></p>
       ${sync?.blocked ? `<p class="err">Plaud blocks requests from Cloudflare's servers, so the connector can't read Plaud directly. Notes can still reach it from the Riff Pocket iPhone app's mirror (see README).</p>` : sync?.error ? `<p class="err">${esc(sync.error)}</p>` : ""}`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Connector setup</title><style>${STYLE}
  .card{width:min(620px,100%)} fieldset{border:1px solid var(--border);border-radius:16px;padding:14px 16px;margin:14px 0}
  legend{font-family:"Iowan Old Style",Palatino,Georgia,serif;font-size:18px;padding:0 6px} select,textarea{width:100%;font:inherit;padding:10px;border-radius:12px;border:1px solid var(--border);background:var(--raised);color:var(--text);margin:6px 0 12px}
  textarea{font-family:ui-monospace,Consolas,monospace;font-size:12px;min-height:70px} .bm{display:inline-block;background:var(--accent);color:#fff;border-radius:999px;padding:8px 14px;text-decoration:none;font-weight:600}
  .ok{color:#5E8C61;font-weight:600} button.small{flex:none;padding:9px 16px}</style></head><body><main class="card">
  <div class="spark">✻</div><h1>Connector setup</h1>
  <p class="muted">${v.notes} note${v.notes === 1 ? "" : "s"} in the connector. Claude connector URL: <code>${esc(v.origin)}/mcp</code></p>
  ${status}
  ${v.message ? `<p class="${v.message.ok ? "ok" : "err"}">${esc(v.message.text)}</p>` : ""}
  <form method="post" autocomplete="off">
    <label class="muted" for="pw">Connector password (OWNER_PASSWORD) — needed for every action here</label>
    <input id="pw" name="password" type="password" autocomplete="current-password" required>
    ${v.otp ? `
    <fieldset><legend>Enter the code Plaud emailed to ${esc(v.otp.email)}</legend>
      <input type="hidden" name="otp_token" value="${esc(v.otp.otpToken)}"><input type="hidden" name="api_base" value="${esc(v.otp.apiBase)}">
      <input name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="6-digit code">
      <button class="allow small" name="action" value="verify_code">Connect</button>
    </fieldset>` : `
    <fieldset><legend>Signed up with Apple or Google</legend>
      <ol class="muted">
        <li>Drag this button to your browser's bookmarks bar: <a class="bm" href="${esc(bookmarklet)}">Send Plaud to Claude</a></li>
        <li>Sign in at <a href="https://web.plaud.ai" target="_blank" rel="noopener">web.plaud.ai</a> on a computer, then click the bookmark. It brings you back here with your token filled in.</li>
      </ol>
      <details><summary>Copy it from Firefox or Chrome instead</summary>
        <ol class="muted">
          <li>On <b>web.plaud.ai</b>, signed in, press <b>F12</b>.</li>
          <li>Firefox: open the <b>Storage</b> tab. Chrome or Edge: open <b>Application</b>.</li>
          <li>Under <b>Cookies</b>, click the plaud.ai entry and find <b>pld_ut</b>. If it isn't there, look under <b>Local Storage</b> for <b>pld_tokenstr</b>.</li>
          <li>Double-click its <b>Value</b>, copy it (it starts with <code>eyJ</code>), and paste it below.</li>
        </ol>
      </details>
      <textarea id="token" name="token" placeholder="…or paste your Plaud sign-in token (it starts with eyJ) from web.plaud.ai"></textarea>
      <p id="tokfrom" class="muted"></p>
      <label class="muted">Region</label>
      <select name="region"><option value="">Detect automatically</option><option value="global">Global (api.plaud.ai)</option><option value="eu">EU (api-euc1)</option><option value="apac">Asia Pacific (api-apse1)</option><option value="china">China (api.plaud.cn)</option></select>
      <button class="allow small" name="action" value="token">Connect Plaud</button>
    </fieldset>
    <fieldset><legend>Signed up with email</legend>
      <input name="email" type="email" placeholder="you@example.com">
      <button class="allow small" name="action" value="send_code">Email me a code</button>
    </fieldset>`}
    ${v.plaud.connected ? `
    <fieldset><legend>Sync</legend>
      <p class="muted">The connector checks Plaud every 30 minutes and fetches Plaud's transcripts and summaries.</p>
      <div class="row"><button class="allow small" name="action" value="sync">Sync now</button>
      <button class="deny small" name="action" value="disconnect" formnovalidate>Disconnect Plaud</button></div>
    </fieldset>` : ""}
  </form>
  <h2 style="font-family:Iowan Old Style,Georgia,serif;font-weight:500">Add to Claude</h2>
  <ol><li>claude.ai → <strong>Customize → Connectors → Add custom connector</strong></li>
      <li>URL: <code>${esc(v.origin)}/mcp</code> → <strong>Connect</strong> → enter the connector password → <strong>Allow</strong></li>
      <li>It's then also in the Claude iPhone app. Turn on Claude's <strong>Notion</strong> connector to save notes to Notion.</li></ol>
  </main>
  <script nonce="${esc(v.nonce)}">
    const m = location.hash.match(/(?:token|session)=([^&]+)/);
    const f = location.hash.match(/from=([^&]+)/);
    if (m) {
      document.getElementById('token').value = decodeURIComponent(m[1]);
      if (f) document.getElementById('tokfrom').textContent = 'Found in web.plaud.ai saved data: ' + decodeURIComponent(f[1]);
      history.replaceState(null, '', location.pathname); document.getElementById('pw').focus();
    }
  </script></body></html>`;
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "X-Frame-Options": "DENY",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": `default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${v.nonce}'; form-action 'self'; frame-ancestors 'none'`,
    },
  });
}

export function landingPage(origin: string, notes: number, plaudConnected: boolean): Response {
  return new Response(page("Riff Pocket connector", `
    <div class="spark">✻</div>
    <h1>Riff Pocket connector</h1>
    <p>Your recorded notes in Claude — on claude.ai, the desktop app and the Claude iPhone app.</p>
    <p class="muted">${notes} note${notes === 1 ? "" : "s"} mirrored · Plaud ${plaudConnected ? "connected" : "not connected"}</p>
    <ol>
      <li><a href="/setup">Connect your Plaud account</a> (once).</li>
      <li>In Claude: <strong>Customize → Connectors → Add custom connector</strong>.</li>
      <li>URL: <code>${esc(origin)}/mcp</code> → <strong>Connect</strong> → enter your connector password.</li>
      <li>On iPhone, it appears automatically in the Claude app.</li>
    </ol>`), {
    headers: { "Content-Type": "text/html; charset=utf-8", "X-Frame-Options": "DENY" },
  });
}
