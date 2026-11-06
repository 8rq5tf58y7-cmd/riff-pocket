// Riff Desk web app — talks to the local /ui API (this computer only).
const $ = (s, el = document) => el.querySelector(s);
const state = { data: null, scope: "all", search: "", noteId: null, note: null, tab: "summary", view: "notes", chats: {} };

async function api(path, opts = {}) {
  const res = await fetch("/ui/" + path, {
    method: opts.method || "GET",
    headers: opts.body && !(opts.body instanceof Blob || opts.body instanceof File) ? { "Content-Type": "application/json" } : {},
    body: opts.body && !(opts.body instanceof Blob || opts.body instanceof File) ? JSON.stringify(opts.body) : opts.body,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const clock = (t) => { t = Math.max(0, Math.floor(t || 0)); return [t / 3600, (t % 3600) / 60, t % 60].map((n) => String(Math.floor(n)).padStart(2, "0")).join(":"); };
const dur = (t) => { t = Math.round(t || 0); const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60; return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`; };

function md(src) {
  const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/\*(.+?)\*/g, "<i>$1</i>").replace(/`(.+?)`/g, "<code>$1</code>")
    .replace(/\[(\d{2}:\d{2}:\d{2})\]/g, '<a href="#" class="ts-link" data-ts="$1">[$1]</a>');
  let html = "", list = false;
  for (const raw of String(src || "").split("\n")) {
    const line = raw.trim();
    const li = line.match(/^([-*•]|\d+\.)\s+(.*)$/);
    if (li) { if (!list) { html += "<ul>"; list = true; } html += `<li>${inline(li[2])}</li>`; continue; }
    if (list) { html += "</ul>"; list = false; }
    const h = line.match(/^(#{1,3})\s+(.*)$/);
    if (h) html += `<h${h[1].length + 1}>${inline(h[2])}</h${h[1].length + 1}>`;
    else if (line) html += `<p>${inline(line)}</p>`;
  }
  return `<div class="md">${html}${list ? "</ul>" : ""}</div>`;
}

// ---------------------------------------------------------------- loading
async function refresh() {
  state.data = await api("state");
  renderSidebar();
  renderList();
  if (state.view === "notes" && state.noteId) {
    const fresh = state.data.notes.find((n) => n.id === state.noteId);
    if (fresh && state.note && fresh.updatedAt !== state.note.updatedAt) await openNote(state.noteId, true);
  }
}

function scoped() {
  const q = state.search.toLowerCase();
  return state.data.notes.filter((n) =>
    (state.scope === "all" || (state.scope === "unfiled" ? !n.folderId : n.folderId === state.scope)) &&
    (!q || n.title.toLowerCase().includes(q) || (n.summary || "").toLowerCase().includes(q)));
}

// ---------------------------------------------------------------- sidebar + list
function renderSidebar() {
  const { notes, folders, worker } = state.data;
  const count = (f) => notes.filter(f).length;
  const items = [["all", "All notes", count(() => true)], ["unfiled", "Unfiled", count((n) => !n.folderId)],
    ...folders.map((f) => [f.id, f.name, count((n) => n.folderId === f.id)])];
  $("#folders").innerHTML = items.map(([id, name, c]) =>
    `<a data-scope="${esc(id)}" class="${state.scope === id ? "active" : ""}"><span>${id === "all" || id === "unfiled" ? "" : "📁 "}${esc(name)}</span><span class="count">${c}</span></a>`).join("");
  $("#folders").querySelectorAll("a").forEach((a) => a.onclick = () => { state.scope = a.dataset.scope; renderSidebar(); renderList(); if (state.view === "chat") openChat(); });
  $("#workerStatus").innerHTML = worker.status === "Idle"
    ? (worker.lastError ? `<span class="danger">${esc(worker.lastError)}</span>` : "Idle · synced")
    : `<span class="thinking">${esc(worker.status)}</span>`;
}

function renderList() {
  const notes = scoped();
  const pending = state.data.worker.pending;
  const banner = $("#pendingBanner");
  banner.classList.toggle("hidden", !pending);
  banner.innerHTML = `<span class="spark">✻</span><span>${pending} note${pending === 1 ? "" : "s"} waiting to be processed</span><button class="primary" id="processAll">Process</button>`;
  if (pending) $("#processAll").onclick = async () => { await api("process-all", { method: "POST" }); setTimeout(refresh, 800); };

  let html = "", lastDay = "";
  for (const n of notes) {
    const d = new Date(n.createdAt * 1000);
    const day = d.toDateString() === new Date().toDateString() ? "Today" : d.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" });
    if (day !== lastDay) { html += `<div class="day">${esc(day)}</div>`; lastDay = day; }
    const preview = (n.summary || "").split("\n")
      .map((l) => l.replace(/^[#\-*•\d.\s]+/, "").replace(/\*\*|__|`/g, "").replace(/\s*\[\d{2}:\d{2}:\d{2}\]/g, ""))
      .filter((l) => l && !/^(summary|overview|tl;dr)$/i.test(l)).slice(0, 2).join(" · ");
    html += `<div class="note ${n.id === state.noteId && state.view === "notes" ? "active" : ""}" data-id="${esc(n.id)}">
      <div class="t">${esc(n.title)}</div>${preview ? `<div class="p">${esc(preview)}</div>` : ""}
      <div class="m"><span>${d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span><span>${dur(n.duration)}</span>
      ${n.summary ? '<span class="pill accent">summary</span>' : n.hasTranscript ? '<span class="pill">transcript</span>' : n.hasAudio ? '<span class="pill">audio</span>' : ""}
      ${n.attachments?.length ? `<span class="pill">📎 ${n.attachments.length}</span>` : ""}</div></div>`;
  }
  $("#notes").innerHTML = html || `<p class="muted" style="padding:16px">No notes here yet.</p>`;
  $("#notes").querySelectorAll(".note").forEach((el) => el.onclick = () => openNote(el.dataset.id));
}

// ---------------------------------------------------------------- note view
async function openNote(id, keepTab) {
  state.view = "notes";
  state.noteId = id;
  if (!keepTab) state.tab = "summary";
  state.note = await api("notes/" + encodeURIComponent(id));
  renderList();
  renderNote();
}

function renderNote() {
  const n = state.note;
  const folderOpts = `<option value="">No folder</option>` + state.data.folders.map((f) => `<option value="${esc(f.id)}" ${f.id === n.folderId ? "selected" : ""}>${esc(f.name)}</option>`).join("");
  const segs = n.transcript?.segments || [];
  const tabs = ["summary", "transcript", "ask", "files"];
  let body = "";
  if (state.tab === "summary") {
    body = n.summary
      ? `<div class="muted mono small">${esc(n.summarySource === "plaud" ? "From Plaud" : "By " + (n.summarySource || ""))}</div>${md(n.summary)}`
      : `<div class="card"><h3>No summary yet</h3><p class="muted">${segs.length ? "Summarize with your desktop model." : "Transcribe first."}</p></div>`;
  } else if (state.tab === "transcript") {
    body = segs.length ? segs.map((s) => `<div class="seg" data-t="${s.start}"><div class="ts">${clock(s.start)}</div><div>${s.speaker ? `<div class="sp">${esc(s.speaker)}</div>` : ""}${esc(s.text)}</div></div>`).join("")
      : `<div class="card"><h3>No transcript</h3><p class="muted">${n.hasAudio ? "It'll be transcribed automatically, or press Process." : "No audio on this computer yet."}</p></div>`;
  } else if (state.tab === "files") {
    const atts = (n.attachments || []).filter((a) => !a.deleted);
    body = `<div class="files"><ul>${atts.map((a) => `<li>📎 <a href="/ui/notes/${encodeURIComponent(n.id)}/attachments/${encodeURIComponent(a.id)}" target="_blank">${esc(a.name)}</a>
      ${a.text ? '<span class="pill ok">used by Ask</span>' : '<span class="pill">no text</span>'}
      <button class="ghost danger small" data-del="${esc(a.id)}">Remove</button></li>`).join("") || '<li class="muted">No files attached.</li>'}</ul>
      <label class="ghost upload">Attach file…<input type="file" id="attachFile" multiple hidden></label>
      <p class="muted small">Text, Markdown and CSV files are read here; PDFs and photos are read on the iPhone when attached there.</p></div>`;
  }
  const detail = $("#detail");
  detail.innerHTML = `<div class="note-view">
    <input class="title-input" id="title" value="${esc(n.title)}" title="Rename (locks the name against automatic titles)">
    <div class="meta">
      <span class="mono muted">${new Date(n.createdAt * 1000).toLocaleString()}</span>
      ${n.source === "plaud" ? '<span class="pill">Plaud</span>' : ""}${n.titleLocked ? '<span class="pill">named by you</span>' : ""}
      <select id="folder">${folderOpts}</select>
    </div>
    ${n.hasAudio ? `<audio id="audio" controls preload="metadata" src="/ui/notes/${encodeURIComponent(n.id)}/audio"></audio>` : ""}
    <div class="tabs">${tabs.map((t) => `<button data-tab="${t}" class="${state.tab === t ? "on" : ""}">${t[0].toUpperCase() + t.slice(1)}</button>`).join("")}</div>
    <div id="tabBody">${state.tab === "ask" ? "" : body}</div>
    ${state.tab === "summary" || state.tab === "transcript" ? `<div class="actions">
      <button class="primary" id="process">${segs.length ? (n.summary ? "Regenerate summary" : "Summarize") : "Transcribe & summarize"}</button>
      <button class="ghost" id="retitle" ${segs.length || n.summary ? "" : "disabled"}>Rename from content</button>
      <button class="ghost danger" id="deleteNote">Delete</button></div>` : ""}
  </div>`;
  if (state.tab === "ask") mountChat($("#tabBody"), { key: "note:" + n.id, title: "", note: n });

  $("#title").onchange = async (e) => { state.note = await api("notes/" + encodeURIComponent(n.id), { method: "PATCH", body: { title: e.target.value } }); refresh(); };
  $("#folder").onchange = async (e) => { state.note = await api("notes/" + encodeURIComponent(n.id), { method: "PATCH", body: { folderId: e.target.value || null } }); refresh(); };
  detail.querySelectorAll("[data-tab]").forEach((b) => b.onclick = () => { state.tab = b.dataset.tab; renderNote(); });
  detail.querySelectorAll(".seg").forEach((el) => el.onclick = () => { const a = $("#audio"); if (a) { a.currentTime = +el.dataset.t; a.play(); } });
  detail.querySelectorAll(".ts-link").forEach((el) => el.onclick = (e) => { e.preventDefault(); const a = $("#audio"); const [h, m, s] = el.dataset.ts.split(":").map(Number); if (a) { a.currentTime = h * 3600 + m * 60 + s; a.play(); } });
  const proc = $("#process");
  if (proc) proc.onclick = async () => { proc.disabled = true; proc.textContent = "Working…"; await api(`notes/${encodeURIComponent(n.id)}/process`, { method: "POST", body: { summary: true } }); pollNote(n.id); };
  const rt = $("#retitle");
  if (rt) rt.onclick = async () => { rt.disabled = true; await api(`notes/${encodeURIComponent(n.id)}/process`, { method: "POST", body: { title: true } }); pollNote(n.id); };
  const del = $("#deleteNote");
  if (del) del.onclick = async () => { if (confirm("Delete this note on all devices?")) { await api("notes/" + encodeURIComponent(n.id), { method: "PATCH", body: { deleted: true } }); state.noteId = null; $("#detail").innerHTML = ""; refresh(); } };
  const af = $("#attachFile");
  if (af) af.onchange = async () => { for (const f of af.files) state.note = await api(`notes/${encodeURIComponent(n.id)}/attachments?name=${encodeURIComponent(f.name)}`, { method: "POST", body: f }); renderNote(); refresh(); };
  detail.querySelectorAll("[data-del]").forEach((b) => b.onclick = async () => { state.note = await api(`notes/${encodeURIComponent(n.id)}/attachments/${encodeURIComponent(b.dataset.del)}`, { method: "DELETE" }); renderNote(); });
}

function pollNote(id) {
  const started = Date.now();
  const tick = async () => { await refresh(); if (state.noteId === id) await openNote(id, true); if (Date.now() - started < 10 * 60e3 && state.data.worker.status !== "Idle") setTimeout(tick, 2000); };
  setTimeout(tick, 1500);
}

// ---------------------------------------------------------------- chat
function scopeName(scope) {
  if (scope === "all") return "All notes";
  if (scope === "unfiled") return "Unfiled";
  return state.data.folders.find((f) => f.id === scope)?.name || "Folder";
}

function openChat() {
  state.view = "chat";
  renderList();
  mountChat($("#detail"), { key: "library", title: "Chat with your notes", library: true });
}

function mountChat(container, opts) {
  const tpl = $("#chatTpl").content.cloneNode(true);
  container.innerHTML = "";
  container.appendChild(tpl);
  const root = container.querySelector(".chat");
  const history = (state.chats[opts.key] ||= []);
  root.querySelector(".chat-title").textContent = opts.title;
  const scopeSel = root.querySelector(".scope");
  if (opts.library) {
    scopeSel.innerHTML = [["all", "All notes"], ["unfiled", "Unfiled"], ...state.data.folders.map((f) => [f.id, f.name])]
      .map(([v, l]) => `<option value="${esc(v)}" ${v === state.scope ? "selected" : ""}>${esc(l)}</option>`).join("");
    scopeSel.onchange = () => { state.scope = scopeSel.value; renderSidebar(); renderList(); };
  } else { scopeSel.remove(); root.querySelector(".chat-head").remove(); }
  const chat = state.data.config.chat;
  root.querySelector(".model").textContent = `${chat.kind} · ${chat.model || "default"}`;
  const box = root.querySelector(".messages");
  const draw = (thinking) => {
    box.innerHTML = history.length ? history.map((m) => m.role === "user" ? `<div class="msg user">${esc(m.content)}</div>` : `<div class="msg assistant">${md(m.content)}</div>`).join("")
      : `<div class="suggest"><div class="spark big">✻</div><h2>${opts.library ? "Ask across " + esc(scopeName(state.scope)) : "Ask about this note"}</h2>
         ${["What were the key decisions?", "List every action item with its owner", "What questions are still open?"].map((s) => `<button>${s}</button>`).join("")}</div>`;
    if (thinking) box.innerHTML += `<div class="thinking">Reading your notes…</div>`;
    box.querySelectorAll(".suggest button").forEach((b) => b.onclick = () => send(b.textContent));
    box.scrollTop = box.scrollHeight;
  };
  const ta = root.querySelector("textarea");
  ta.oninput = () => { ta.style.height = "auto"; ta.style.height = ta.scrollHeight + "px"; };
  ta.onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(ta.value); } };
  root.querySelector(".composer").onsubmit = (e) => { e.preventDefault(); send(ta.value); };
  async function send(q) {
    q = q.trim();
    if (!q) return;
    ta.value = "";
    const prior = history.slice();
    history.push({ role: "user", content: q });
    draw(true);
    try {
      const r = opts.library ? await api("chat", { method: "POST", body: { question: q, scope: state.scope, history: prior } })
        : await api(`notes/${encodeURIComponent(opts.note.id)}/ask`, { method: "POST", body: { question: q, history: prior } });
      history.push({ role: "assistant", content: r.answer });
    } catch (err) {
      history.push({ role: "assistant", content: "⚠️ " + err.message });
    }
    draw(false);
  }
  draw(false);
}

// ---------------------------------------------------------------- settings
function fillSettings() {
  const c = state.data.config;
  const s = c.settings || {};
  $("#tKind").value = c.transcription.kind; $("#tBase").value = c.transcription.baseURL || ""; $("#tModel").value = c.transcription.model || ""; $("#tKey").value = c.transcription.apiKey || "";
  $("#cKind").value = c.chat.kind; $("#cBase").value = c.chat.baseURL || ""; $("#cModel").value = c.chat.model || ""; $("#cKey").value = c.chat.apiKey || "";
  $("#plaudMinutes").value = c.plaudSyncMinutes;
  $("#autoTranscribe").checked = s.autoTranscribe !== false; $("#autoSummarize").checked = s.autoSummarize !== false; $("#autoTitle").checked = s.autoTitle !== false;
  $("#plaudStatus").textContent = c.plaudConnected
    ? "Connected — new Plaud recordings are pulled here and processed automatically."
    : "Not connected. In Riff Pocket: Settings → Desktop companion → “Let the desktop sync Plaud”.";
  const p = state.data.pairing;
  $("#pairUrls").innerHTML = p.urls.map(esc).join("<br>") || "No network address found — connect this computer to Wi-Fi.";
  const link = p.links[0];
  if (link && window.qrcode) { const qr = qrcode(0, "M"); qr.addData(link); qr.make(); $("#qr").innerHTML = qr.createSvgTag({ cellSize: 4, margin: 2 }); }
  else $("#qr").innerHTML = `<span class="muted small">${link ? "QR needs internet once (qrcode library). Copy the link instead." : ""}</span>`;
  $("#copyLink").onclick = () => link && navigator.clipboard.writeText(link).then(() => ($("#copyLink").textContent = "Copied ✓"));
}

async function saveSettings() {
  await api("config", { method: "PUT", body: {
    transcription: { kind: $("#tKind").value, baseURL: $("#tBase").value.trim(), model: $("#tModel").value.trim(), apiKey: $("#tKey").value },
    chat: { kind: $("#cKind").value, baseURL: $("#cBase").value.trim(), model: $("#cModel").value.trim(), apiKey: $("#cKey").value },
    plaudSyncMinutes: +$("#plaudMinutes").value || 0,
    settings: { autoTranscribe: $("#autoTranscribe").checked, autoSummarize: $("#autoSummarize").checked, autoTitle: $("#autoTitle").checked },
  } });
  $("#saveMsg").textContent = "Saved ✓";
  await refresh();
}

// ---------------------------------------------------------------- wiring
window.addEventListener("DOMContentLoaded", async () => {
  await refresh();
  $("#search").oninput = (e) => { state.search = e.target.value; renderList(); };
  $("#chatBtn").onclick = openChat;
  $("#newFolderBtn").onclick = async () => { const name = prompt("Folder name"); if (name) { await api("folders", { method: "POST", body: { name } }); refresh(); } };
  $("#settingsBtn").onclick = () => { fillSettings(); $("#saveMsg").textContent = ""; $("#settings").showModal(); };
  $("#saveSettings").onclick = saveSettings;
  $("#resetToken").onclick = async () => { if (confirm("Reset pairing? Paired phones will need to scan the new code.")) { state.data.pairing = await api("pairing/reset", { method: "POST" }); fillSettings(); } };
  $("#plaudSync").onclick = async () => { await api("plaud/sync", { method: "POST" }); setTimeout(refresh, 1500); };
  $("#plaudDisconnect").onclick = async () => { if (confirm("Stop syncing Plaud on this computer?")) { await api("plaud/disconnect", { method: "POST" }); await refresh(); fillSettings(); } };
  $("#importAudio").onchange = async (e) => {
    for (const f of e.target.files) await api(`import?name=${encodeURIComponent(f.name)}${state.scope.length > 10 ? "&folderId=" + encodeURIComponent(state.scope) : ""}`, { method: "POST", body: f });
    e.target.value = ""; refresh();
  };
  setInterval(() => { if (!$("#settings").open) refresh().catch(() => {}); }, 5000);
});
