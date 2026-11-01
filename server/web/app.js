// Kervan's web client: sessions, the conversation, approvals and stop, from any browser that can reach the server.
// It speaks the same WebSocket protocol as the Mac app (protocol/v1.md); there is no build step.

const PROTOCOL = 1;
// This browser's own key, from pairing; never the server's key.
const KEY_STORE = "kervan.device";
const LANG_STORE = "kervan.lang";

// MARK: Storage and language

const stored = {
  get(name) {
    try { return localStorage.getItem(name); } catch { return null; }
  },
  set(name, value) {
    try {
      if (value === null) localStorage.removeItem(name);
      else localStorage.setItem(name, value);
    } catch { /* private mode: it just won't be remembered */ }
  },
};

let lang = stored.get(LANG_STORE) || ((navigator.language || "").toLowerCase().startsWith("tr") ? "tr" : "en");
const L = (english, turkish) => (lang === "tr" ? turkish : english);

// MARK: State

const state = {
  key: stored.get(KEY_STORE),
  signInError: null,
  checking: false,
  connection: "offline", // offline | connecting | connected
  server: null,
  agents: [], // [{id, name}]
  sessions: new Map(),
  events: new Map(), // sessionId → Map(seq → event)
  open: null,
  // The project whose board is showing (#/p/<id>), its projects and their cards.
  board: null,
  projects: [],
  boards: new Map(),
  flash: null,
  menu: false,
  drafts: new Map(),
  attachments: new Map(), // sessionId → Array<{ id, name, path?, state, error? }>
};

// MARK: Connection

let socket = null;
let retry = 0;
let retryTimer = null;
let counter = 0;
const pending = new Map();

const base64url = (text) =>
  btoa(String.fromCharCode(...new TextEncoder().encode(text))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Checks the key over HTTP first: a browser WebSocket can't tell a wrong key from a server that's down. */
/** "iPhone · Safari", so the device list in the app says which browser is which. */
function deviceName() {
  const agent = navigator.userAgent;
  const system = /iPhone/.test(agent) ? "iPhone" : /iPad/.test(agent) ? "iPad" : /Android/.test(agent) ? "Android"
    : /Mac OS X/.test(agent) ? "Mac" : /Windows/.test(agent) ? "Windows" : /Linux/.test(agent) ? "Linux" : "Browser";
  const browser = /Edg\//.test(agent) ? "Edge" : /Firefox\//.test(agent) ? "Firefox" : /Chrome\//.test(agent) ? "Chrome"
    : /Safari\//.test(agent) ? "Safari" : "";
  return browser ? `${system} · ${browser}` : system;
}

/** Trades the one-time code from the app for this browser's own key. */
async function signIn(code) {
  state.checking = true;
  state.signInError = null;
  render();
  try {
    const response = await fetch("/v1/web/pair", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code, name: deviceName() }),
      cache: "no-store",
    });
    if (response.status === 401) throw new Error(L("That code is wrong or has expired. Make a new one in the app.", "Kod yanlış ya da süresi dolmuş. Uygulamada yenisini oluşturun."));
    if (response.status === 403) throw new Error(L("Web access is off. Turn it on in the app first.", "Web erişimi kapalı. Önce uygulamadan açın."));
    if (response.status === 429) throw new Error(L("Too many tries. Wait a few minutes, then try again.", "Çok fazla deneme. Birkaç dakika bekleyip tekrar deneyin."));
    if (!response.ok) throw new Error(L(`The server answered ${response.status}.`, `Sunucu ${response.status} yanıtı verdi.`));
    const { token } = await response.json();
    state.key = token;
    stored.set(KEY_STORE, token);
    connect();
  } catch (error) {
    state.signInError = error instanceof TypeError ? L("Can't reach the server.", "Sunucuya ulaşılamıyor.") : error.message;
  } finally {
    state.checking = false;
    render();
  }
}

function signOut() {
  stored.set(KEY_STORE, null);
  state.key = null;
  state.menu = false;
  clearTimeout(retryTimer);
  if (socket) {
    socket.onclose = null;
    socket.close();
  }
  socket = null;
  state.connection = "offline";
  state.sessions.clear();
  state.events.clear();
  render();
}

function connect() {
  clearTimeout(retryTimer);
  if (!state.key) return;
  state.connection = "connecting";
  render();
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${scheme}://${location.host}/v1/ws`, ["kervan", `kervan.key.${base64url(state.key)}`]);
  socket = ws;
  ws.onopen = () => {
    ws.send(JSON.stringify({ type: "hello", protocol: PROTOCOL, client: { name: "Kervan for the web", version: "web" } }));
  };
  ws.onmessage = (frame) => {
    let message;
    try { message = JSON.parse(frame.data); } catch { return; }
    receive(message);
  };
  ws.onclose = (event) => {
    if (socket !== ws) return;
    if (event.code === 4001) {
      state.signInError = L("This browser's access was removed in the Kervan app. Pair it again to come back.", "Bu tarayıcının erişimi Kervan uygulamasından kaldırıldı. Geri dönmek için yeniden eşleştirin.");
      signOut();
      return;
    }
    socket = null;
    state.connection = "offline";
    for (const { reject } of pending.values()) reject(new Error(L("The connection dropped.", "Bağlantı koptu.")));
    pending.clear();
    render();
    // The key can stop working (the device was removed, or web access turned off); check before trying again.
    const delay = Math.min(30, 2 ** retry++) * 1000;
    retryTimer = setTimeout(async () => {
      const check = await fetch("/v1/check", { headers: { authorization: `Bearer ${state.key}` }, cache: "no-store" }).catch(() => null);
      if (check?.status === 401) {
        state.signInError = L("This browser is no longer paired, or web access was turned off. Pair it again.", "Bu tarayıcının eşleşmesi kaldırılmış ya da web erişimi kapatılmış. Yeniden eşleştirin.");
        signOut();
        return;
      }
      connect();
    }, delay);
  };
}

function request(message) {
  const id = `w${Date.now().toString(36)}${(counter++).toString(36)}`;
  return new Promise((resolve, reject) => {
    if (!socket || socket.readyState !== WebSocket.OPEN || state.connection !== "connected") {
      reject(new Error(L("Not connected to the server.", "Sunucuya bağlı değil.")));
      return;
    }
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ ...message, id }));
  });
}

function receive(message) {
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.type === "error") reject(new Error(message.message));
    else resolve(message);
  }
  switch (message.type) {
    case "welcome":
      retry = 0;
      state.connection = "connected";
      state.server = message.server;
      state.agents = message.agentDetails ?? message.agents.map((id) => ({ id, name: id }));
      void loadSessions();
      void request({ type: "project.list" }).catch(() => {});
      if (state.board) void loadBoard(state.board);
      break;
    case "agents.updated":
      state.agents = message.agentDetails ?? state.agents;
      break;
    case "session.list.result":
      state.sessions = new Map(message.sessions.map((s) => [s.id, s]));
      if (state.open) void loadHistory(state.open);
      break;
    case "session.created":
    case "session.updated": {
      const session = message.session;
      state.sessions.set(session.id, session);
      break;
    }
    case "project.list.result":
    case "projects.updated":
      state.projects = message.projects;
      break;
    case "board.result":
    case "board.updated":
      state.boards.set(message.projectId, message.cards);
      break;
    case "session.event": {
      const events = state.events.get(message.sessionId);
      if (events) events.set(message.event.seq, message.event);
      break;
    }
    case "error":
      if (!message.id) showFlash(message.message);
      break;
    default:
      return;
  }
  scheduleRender();
}

async function loadSessions() {
  try { await request({ type: "session.list" }); } catch (error) { showFlash(error.message); }
}

async function loadBoard(projectId) {
  try { await request({ type: "board.list", projectId }); } catch (error) { showFlash(error.message); }
}

async function loadHistory(sessionId) {
  try {
    const answer = await request({ type: "session.history", sessionId });
    const events = state.events.get(sessionId) ?? new Map();
    for (const event of answer.events) events.set(event.seq, event);
    state.events.set(sessionId, events);
    scheduleRender(true);
  } catch (error) {
    showFlash(error.message);
  }
}

function showFlash(text) {
  state.flash = text;
  render();
  setTimeout(() => {
    if (state.flash === text) {
      state.flash = null;
      render();
    }
  }, 6000);
}

// MARK: Actions

async function uploadAttachment(sessionId, file) {
  const list = state.attachments.get(sessionId) ?? [];
  const id = "att-" + Math.random().toString(36).slice(2, 9);
  const entry = { id, name: file.name, state: "uploading" };
  list.push(entry);
  state.attachments.set(sessionId, list);
  render();

  try {
    const res = await fetch(`/v1/sessions/${encodeURIComponent(sessionId)}/files?name=${encodeURIComponent(file.name)}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${state.key}`,
        "content-type": file.type || "application/octet-stream",
      },
      body: file,
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.message || err.error || `Upload failed (${res.status})`);
    }
    const data = await res.json();
    entry.path = data.path;
    entry.state = "ready";
  } catch (error) {
    entry.state = "failed";
    entry.error = error.message;
    showFlash(error.message);
  }
  render();
}

async function send(sessionId, text, attachments = []) {
  try {
    const payload = { type: "session.prompt", sessionId, text };
    if (attachments && attachments.length > 0) payload.attachments = attachments;
    await request(payload);
    state.drafts.delete(sessionId);
    state.attachments.delete(sessionId);
  } catch (error) {
    showFlash(error.message);
  }
}

async function stop(sessionId) {
  try { await request({ type: "session.cancel", sessionId }); } catch (error) { showFlash(error.message); }
}

async function answer(sessionId, requestId, optionId) {
  try { await request({ type: "session.permission", sessionId, requestId, optionId }); } catch (error) { showFlash(error.message); }
}

async function create(agent, split = false) {
  try {
    const payload = { type: "session.create", agent };
    if (split) {
      payload.orchestrate = true;
      payload.split = true;
    }
    const answer = await request(payload);
    state.sessions.set(answer.session.id, answer.session);
    location.hash = `#/s/${answer.session.id}`;
  } catch (error) {
    showFlash(error.message);
  }
}

// MARK: Routing

function route() {
  const match = /^#\/s\/(.+)$/.exec(location.hash);
  const board = /^#\/p\/(.+)$/.exec(location.hash);
  state.open = match ? decodeURIComponent(match[1]) : null;
  state.board = board ? decodeURIComponent(board[1]) : null;
  state.menu = false;
  if (state.board && state.connection === "connected") void loadBoard(state.board);
  if (state.open && !state.events.has(state.open) && state.connection === "connected") void loadHistory(state.open);
  render(true);
}

window.addEventListener("hashchange", route);

// MARK: Building the page

function h(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value === undefined || value === null || value === false) continue;
    if (name.startsWith("on")) element.addEventListener(name.slice(2), value);
    else if (name === "class") element.className = value;
    else if (name === "html") element.innerHTML = value;
    else element.setAttribute(name, value === true ? "" : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    element.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return element;
}

const ICONS = {
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>',
  back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
  more: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>',
  send: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>',
  stop: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>',
  paperclip: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>',
};

const icon = (name) => h("span", { html: ICONS[name], "aria-hidden": "true", class: "icon" });

const agentName = (id) => state.agents.find((a) => a.id === id)?.name ?? id;

function statusText(session) {
  switch (session.status) {
    case "waiting": return L("Waiting for you", "Onayınızı bekliyor");
    case "running": return L("Working", "Çalışıyor");
    case "starting": return L("Starting", "Başlıyor");
    case "idle": return L("Ready", "Hazır");
    case "error": return session.error ? L(`Error: ${session.error}`, `Hata: ${session.error}`) : L("Error", "Hata");
    case "closed": return L("Closed", "Kapandı");
    default: return session.status;
  }
}

/** Sessions worth listing: not archived, not a lead's helper. Waiting first, then the newest. */
function listedSessions() {
  return [...state.sessions.values()]
    .filter((s) => !s.archived && !s.parentId)
    .sort((a, b) => (b.status === "waiting") - (a.status === "waiting") || b.createdAt.localeCompare(a.createdAt));
}

// MARK: Markdown, safely: everything is escaped first, then a few marks become tags.

const escapeHTML = (text) => text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function inline(escaped) {
  return escaped
    .replace(/`([^`\n]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
    .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>');
}

function markdown(text) {
  const parts = [];
  // A fence still open at the end (the agent is mid-answer) is shown as code too.
  const fence = /```[^\n]*\n?([\s\S]*?)(```|$)/g;
  let last = 0;
  for (let match; (match = fence.exec(text)); ) {
    if (match.index > last) parts.push(prose(text.slice(last, match.index)));
    parts.push(`<pre><code>${escapeHTML(match[1].replace(/\n$/, ""))}</code></pre>`);
    last = fence.lastIndex;
    if (match[0] === "") fence.lastIndex++;
  }
  if (last < text.length) parts.push(prose(text.slice(last)));
  return parts.join("");
}

function prose(text) {
  const out = [];
  let list = null;
  let paragraph = [];
  const flush = () => {
    if (paragraph.length) out.push(`<p>${paragraph.join("<br>")}</p>`);
    paragraph = [];
  };
  const close = () => {
    if (list) out.push(`</${list}>`);
    list = null;
  };
  for (const raw of text.split("\n")) {
    const line = raw.trimEnd();
    const bullet = /^\s*[-*•]\s+(.*)$/.exec(line);
    const numbered = /^\s*\d+[.)]\s+(.*)$/.exec(line);
    const heading = /^#{1,6}\s+(.*)$/.exec(line);
    if (bullet || numbered) {
      flush();
      const kind = bullet ? "ul" : "ol";
      if (list !== kind) {
        close();
        out.push(`<${kind}>`);
        list = kind;
      }
      out.push(`<li>${inline(escapeHTML((bullet ?? numbered)[1]))}</li>`);
    } else if (heading) {
      flush();
      close();
      out.push(`<h4>${inline(escapeHTML(heading[1]))}</h4>`);
    } else if (line.trim() === "") {
      flush();
      close();
    } else {
      close();
      paragraph.push(inline(escapeHTML(line)));
    }
  }
  flush();
  close();
  return out.join("");
}

// MARK: The conversation as blocks: streamed chunks joined, tool updates folded into their call.

function blocks(session, events) {
  const out = [];
  const tools = new Map();
  // Open requests by id; an answer settles the latest request with its id.
  const asks = new Map();
  let plan = null;
  for (const event of events) {
    const previous = out[out.length - 1];
    switch (event.kind) {
      case "user_message":
        out.push({ key: `u${event.seq}`, type: "user", text: event.text, from: event.from, attachments: event.attachments });
        break;
      case "agent_message_chunk":
        if (previous?.type === "agent") previous.text += event.text;
        else out.push({ key: `a${event.seq}`, type: "agent", text: event.text });
        break;
      case "agent_thought_chunk":
        if (previous?.type === "thought") previous.text += event.text;
        else out.push({ key: `h${event.seq}`, type: "thought", text: event.text });
        break;
      case "tool_call": {
        // Keyed by its event: agents may reuse a tool call id in a later turn.
        const block = { key: `t${event.seq}`, type: "tool", title: event.title, status: event.status };
        tools.set(event.toolCallId, block);
        out.push(block);
        break;
      }
      case "tool_call_update": {
        const block = tools.get(event.toolCallId);
        if (block) {
          if (event.title) block.title = event.title;
          if (event.status) block.status = event.status;
        }
        break;
      }
      case "plan":
        plan = { key: "plan", type: "plan", entries: event.entries, at: out.length };
        break;
      case "permission_request": {
        const block = {
          key: `p${event.seq}`,
          type: "permission",
          requestId: event.requestId,
          title: event.title,
          detail: event.detail,
          options: event.options,
          resolved: null,
        };
        asks.set(event.requestId, block);
        out.push(block);
        break;
      }
      case "permission_resolved": {
        const block = asks.get(event.requestId);
        if (!block) break;
        asks.delete(event.requestId);
        const chosen = event.optionId ? block.options.find((o) => o.optionId === event.optionId) : undefined;
        block.resolved = !chosen ? "cancelled" : chosen.kind === "allow_always" ? "always" : chosen.kind.startsWith("allow") ? "allowed" : "denied";
        break;
      }
      case "notice":
        out.push({ key: `n${event.seq}`, type: "notice", text: event.text });
        break;
      case "error":
        out.push({ key: `e${event.seq}`, type: "error", text: event.message });
        break;
      default:
        break;
    }
  }
  // Only the plan as it stands now, where it was last shared.
  if (plan) out.splice(Math.min(plan.at, out.length), 0, { key: plan.key, type: plan.type, entries: plan.entries });
  if (session.status === "running" || session.status === "starting") out.push({ key: "working", type: "working" });
  return out;
}

function toolState(status) {
  switch (status) {
    case "completed": return L("Done", "Bitti");
    case "failed": return L("Failed", "Başarısız");
    case "in_progress": return L("Running", "Çalışıyor");
    default: return L("Pending", "Bekliyor");
  }
}

function renderBlock(block, sessionId) {
  switch (block.type) {
    case "user":
      return h("div", { class: "message user" },
        h("div", {},
          block.from ? h("div", { class: "from" }, L("From the lead", "Liderden")) : null,
          h("div", { class: "bubble" }, block.text),
          block.attachments && block.attachments.length > 0
            ? h("div", { class: "message-attachments" },
                block.attachments.map((att) =>
                  h("span", { class: "message-attachment" }, icon("paperclip"), att.split("/").pop())
                )
              )
            : null));
    case "agent":
      return h("div", { class: "message agent", html: markdown(block.text) });
    case "thought":
      return h("details", { class: "thought" }, h("summary", {}, L("Thinking", "Düşünüyor")), block.text);
    case "tool":
      return h("div", { class: "tool" },
        h("span", { class: "name" }, block.title),
        h("span", { class: `state ${block.status}` }, toolState(block.status)));
    case "plan":
      return h("div", { class: "plan" },
        h("h5", {}, L("Plan", "Plan")),
        h("ul", {}, block.entries.map((entry) =>
          h("li", { class: entry.status },
            h("span", { class: "mark", "aria-hidden": "true" }, entry.status === "completed" ? "✓" : entry.status === "in_progress" ? "●" : "○"),
            h("span", { class: entry.status === "completed" ? "done" : "" }, entry.content)))));
    case "permission":
      return h("div", { class: `permission${block.resolved ? " resolved" : ""}` },
        h("div", { class: "ask" }, h("span", { class: "dot waiting" }), block.resolved ? L("Asked for approval", "Onay istedi") : L("Waiting for your approval", "Onayınızı bekliyor")),
        h("div", { class: "what" }, block.title),
        block.detail ? h("pre", {}, block.detail) : null,
        block.resolved
          ? h("div", { class: "outcome" },
              {
                cancelled: L("Cancelled", "İptal edildi"),
                allowed: L("Allowed", "İzin verildi"),
                always: L("Allowed always", "Her zaman izin verildi"),
                denied: L("Denied", "Reddedildi"),
              }[block.resolved])
          : h("div", { class: "options" }, block.options.map((option) =>
              h("button", {
                class: option.kind === "allow_once" ? "allow" : "",
                onclick: (event) => {
                  event.currentTarget.closest(".options").querySelectorAll("button").forEach((b) => { b.disabled = true; });
                  void answer(sessionId, block.requestId, option.optionId);
                },
              }, option.name))));
    case "notice":
      return h("div", { class: "notice", html: inline(escapeHTML(block.text)) });
    case "error":
      return h("div", { class: "failure" }, block.text);
    case "working":
      return h("div", { class: "working", "aria-label": L("The agent is working", "Ajan çalışıyor") }, h("span"), h("span"), h("span"));
    default:
      return h("div");
  }
}

/** Keeps the elements of blocks that didn't change, so streaming doesn't redraw the whole conversation. */
function reconcile(container, list, sessionId) {
  const existing = new Map([...container.children].map((el) => [el.dataset.key, el]));
  let previous = null;
  for (const block of list) {
    const signature = JSON.stringify(block);
    let element = existing.get(block.key);
    if (!element || element.dataset.sig !== signature) {
      const fresh = renderBlock(block, sessionId);
      fresh.dataset.key = block.key;
      fresh.dataset.sig = signature;
      if (element) element.replaceWith(fresh);
      element = fresh;
    }
    existing.delete(block.key);
    const wanted = previous ? previous.nextSibling : container.firstChild;
    if (wanted !== element) container.insertBefore(element, wanted);
    previous = element;
  }
  for (const element of existing.values()) element.remove();
}

// MARK: Screens

let shell = null;
let renderQueued = false;
let scrollToEnd = false;

function scheduleRender(toEnd = false) {
  scrollToEnd ||= toEnd;
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    render();
  });
}

function render(toEnd = false) {
  scrollToEnd ||= toEnd;
  const root = document.getElementById("app");
  document.documentElement.lang = lang;
  const waiting = [...state.sessions.values()].filter((s) => s.status === "waiting" && !s.archived).length;
  document.title = waiting ? `(${waiting}) Kervan` : "Kervan";

  if (!state.key) {
    shell = null;
    root.replaceChildren(signInScreen());
    return;
  }
  if (!shell) {
    shell = { root: h("div", { class: "shell" }), list: h("section", { class: "list-pane" }), pane: h("section", { class: "session-pane" }) };
    shell.root.append(shell.list, shell.pane);
    root.replaceChildren(shell.root);
  }
  shell.root.classList.toggle("open", Boolean(state.open || state.board));
  shell.list.replaceChildren(...listPane());
  renderSessionPane();
}

function signInScreen() {
  const input = h("input", {
    type: "text",
    name: "code",
    autocomplete: "one-time-code",
    placeholder: "ABCD-EFGH",
    required: true,
    spellcheck: "false",
    autocapitalize: "characters",
    maxlength: "12",
  });
  return h("div", { class: "sign-in" },
    h("form", {
      onsubmit: (event) => {
        event.preventDefault();
        const code = input.value.trim();
        if (code) void signIn(code);
      },
    },
      h("img", { src: "icon.svg", alt: "" }),
      h("h1", {}, L("Kervan on the web", "Web'de Kervan")),
      h("p", {}, L(
        "In the Kervan app on your Mac, open Settings › Web access and choose Add a device. Enter the code it shows; it works once, for ten minutes.",
        "Mac'teki Kervan uygulamasında Ayarlar › Web erişimi'ni açıp Cihaz ekle'yi seçin. Gösterdiği kodu girin; kod bir kez ve on dakika geçerlidir.",
      )),
      h("label", { class: "field" }, h("span", {}, L("Pairing code", "Eşleştirme kodu")), input),
      state.signInError ? h("p", { class: "error-text", role: "alert" }, state.signInError) : null,
      h("div", { class: "row" },
        h("button", { type: "button", class: "quiet", onclick: () => { lang = lang === "tr" ? "en" : "tr"; stored.set(LANG_STORE, lang); render(); } }, lang === "tr" ? "English" : "Türkçe"),
        h("span", { class: "spacer" }),
        h("button", { type: "submit", class: "primary", disabled: state.checking }, state.checking ? L("Pairing…", "Eşleştiriliyor…") : L("Pair this browser", "Bu tarayıcıyı eşleştir")))));
}

function listPane() {
  const connectionLabel = state.connection === "connected"
    ? (state.server ? `${state.server.name} · ${state.server.version}` : L("Connected", "Bağlı"))
    : state.connection === "connecting" ? L("Connecting…", "Bağlanıyor…") : L("Offline, retrying", "Bağlantı yok, yeniden deneniyor");
  const sessions = listedSessions();
  const helpersOf = (leadId) => [...state.sessions.values()]
    .filter((s) => !s.archived && s.parentId === leadId)
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt));

  const needs = sessions.filter((s) => s.status === "waiting" || helpersOf(s.id).some((h) => h.status === "waiting"));
  const rest = sessions.filter((s) => !needs.includes(s));

  const row = (session) => h("button", {
    class: `session-row${session.id === state.open ? " selected" : ""}`,
    onclick: () => { location.hash = `#/s/${encodeURIComponent(session.id)}`; },
  },
    h("span", { class: `dot ${session.status}`, "aria-hidden": "true" }),
    h("span", { class: "text" },
      h("div", { class: "title" }, session.title || agentName(session.agent)),
      h("div", { class: `meta${session.status === "waiting" ? " needs" : ""}` },
        session.role ? `${session.role} · ${statusText(session)}` : `${agentName(session.agent)} · ${statusText(session)}`)));

  const helperRow = (helper) => h("button", {
    class: `session-row helper${helper.id === state.open ? " selected" : ""}`,
    onclick: () => { location.hash = `#/s/${encodeURIComponent(helper.id)}`; },
  },
    h("span", { class: `dot ${helper.status}`, "aria-hidden": "true" }),
    h("span", { class: "text" },
      h("div", { class: "title" }, helper.role || helper.title || agentName(helper.agent)),
      h("div", { class: `meta${helper.status === "waiting" ? " needs" : ""}` },
        `${agentName(helper.agent)} · ${statusText(helper)}`)));

  const leadAndHelpers = (session) => [
    row(session),
    ...helpersOf(session.id).map(helperRow),
  ];

  return [
    h("header", { class: "bar" },
      h("h1", {}, "Kervan"),
      h("span", { class: "connection" }, h("span", { class: `dot ${state.connection === "connected" ? "connected" : state.connection}` }), connectionLabel),
      h("span", { class: "spacer" }),
      h("button", { class: "icon-button", title: L("New session", "Yeni oturum"), "aria-label": L("New session", "Yeni oturum"), disabled: state.connection !== "connected", onclick: openNewSession }, icon("plus")),
      menu()),
    h("div", { class: "sessions" },
      sessions.length === 0
        ? h("p", { class: "empty" }, state.connection === "connected" ? L("No sessions yet. Start one with +.", "Henüz oturum yok. + ile başlatın.") : "")
        : [
            needs.length ? h("h3", {}, L("Needs you", "Sizi bekliyor")) : null,
            ...needs.flatMap(leadAndHelpers),
            needs.length && rest.length ? h("h3", {}, L("Sessions", "Oturumlar")) : null,
            ...rest.flatMap(leadAndHelpers),
          ],
      state.projects.length ? h("h3", {}, L("Boards", "Panolar")) : null,
      state.projects.map((project) => h("button", {
        class: `session-row${project.id === state.board ? " selected" : ""}`,
        onclick: () => { location.hash = `#/p/${encodeURIComponent(project.id)}`; },
      },
        h("span", { class: "text" },
          h("div", { class: "title" }, project.name),
          h("div", { class: "meta" }, L("Task board", "Görev panosu")))))),
  ];
}

const COLUMNS = [
  ["todo", () => L("To do", "Yapılacak")],
  ["working", () => L("Working", "Çalışıyor")],
  ["needs", () => L("Needs you", "Sizi bekliyor")],
  ["review", () => L("Review", "İncelenecek")],
  ["done", () => L("Done", "Bitti")],
];

/** A project's board, to look at: columns of cards; a started card opens its session. Cards are moved from the app. */
function boardPane(projectId) {
  const project = state.projects.find((p) => p.id === projectId);
  const cards = state.boards.get(projectId);
  return [
    h("header", { class: "bar" },
      h("button", { class: "icon-button back", "aria-label": L("Back", "Geri"), onclick: () => { location.hash = "#/"; } }, icon("back")),
      h("div", { class: "head-text" }, h("h2", {}, project?.name ?? L("Board", "Pano")), h("div", { class: "connection" }, L("Cards move here as their sessions work.", "Kartlar oturumları çalıştıkça burada ilerler.")))),
    h("div", { class: "board" },
      !cards
        ? h("p", { class: "empty" }, L("Loading…", "Yükleniyor…"))
        : COLUMNS.map(([column, title]) => {
            const inColumn = cards.filter((c) => c.column === column);
            return h("section", { class: "lane" },
              h("h3", {}, h("span", { class: `dot lane-${column}` }), title(), h("span", { class: "count" }, String(inColumn.length))),
              inColumn.length === 0 ? h("p", { class: "lane-empty" }, "—") : null,
              inColumn.map((card) => h(card.sessionId ? "button" : "div", {
                class: "card",
                onclick: card.sessionId ? () => { location.hash = `#/s/${encodeURIComponent(card.sessionId)}`; } : undefined,
              },
                h("div", { class: "card-title" }, card.title),
                h("div", { class: "card-prompt" }, card.prompt),
                h("div", { class: "card-agent" }, agentName(card.agent)))));
          })),
  ];
}

function menu() {
  return h("div", { class: "menu" },
    h("button", { class: "icon-button", "aria-label": L("More", "Diğer"), "aria-expanded": String(state.menu), onclick: () => { state.menu = !state.menu; render(); } }, icon("more")),
    state.menu
      ? h("div", { class: "menu-list", role: "menu" },
          h("button", { role: "menuitem", onclick: () => { lang = lang === "tr" ? "en" : "tr"; stored.set(LANG_STORE, lang); state.menu = false; render(); } }, lang === "tr" ? "English" : "Türkçe"),
          h("button", { role: "menuitem", onclick: signOut, title: L("Forgets this browser's key here; remove the device in the app to end it there too.", "Bu tarayıcıdaki anahtarı siler; tamamen kaldırmak için cihazı uygulamadan da silin.") }, L("Sign out", "Çıkış yap")))
      : null);
}

function openNewSession() {
  let split = false;
  const splitCheckbox = h("input", {
    type: "checkbox",
    id: "split-helpers",
    onchange: (e) => { split = e.target.checked; },
  });
  const dialog = h("dialog", { "aria-label": L("New session", "Yeni oturum") },
    h("h2", {}, L("Start a session with", "Oturum başlat:")),
    state.agents.map((agent) => h("button", {
      class: "agent-choice",
      onclick: () => { dialog.close(); void create(agent.id, split); },
    }, h("span", { class: "dot idle", "aria-hidden": "true" }), agent.name)),
    h("label", { class: "check-row" },
      splitCheckbox,
      h("span", {}, L("Split into helpers when the work is large", "İş büyük olduğunda yardımcılara böl"))),
    h("div", { class: "row" }, h("span", { class: "spacer" }), h("button", { class: "quiet", onclick: () => dialog.close() }, L("Cancel", "Vazgeç"))));
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}

let paneFor = null;
let paneParts = null;

function renderSessionPane() {
  if (state.board && !state.open) {
    paneFor = null;
    paneParts = null;
    shell.pane.replaceChildren(...boardPane(state.board));
    return;
  }
  const session = state.open ? state.sessions.get(state.open) : null;
  if (!session) {
    paneFor = null;
    paneParts = null;
    shell.pane.replaceChildren(h("p", { class: "empty" },
      state.open && state.connection === "connected" && state.sessions.size ? L("This session isn't on the server any more.", "Bu oturum artık sunucuda yok.")
        : L("Pick a session, or start a new one with +.", "Bir oturum seçin ya da + ile yenisini başlatın.")));
    return;
  }
  if (paneFor !== session.id) {
    paneFor = session.id;
    paneParts = buildPane(session.id);
    shell.pane.replaceChildren(paneParts.header, paneParts.flash, paneParts.transcript, paneParts.composer);
    scrollToEnd = true;
  }
  const busy = session.status === "running" || session.status === "starting" || session.status === "waiting";
  paneParts.title.textContent = session.title || agentName(session.agent);
  paneParts.status.className = `dot ${session.status}`;
  paneParts.statusText.textContent = `${agentName(session.agent)} · ${statusText(session)}`;
  paneParts.flash.hidden = !state.flash;
  paneParts.flash.textContent = state.flash ?? "";
  paneParts.button.className = `send${busy ? " stop" : ""}`;
  paneParts.button.replaceChildren(icon(busy ? "stop" : "send"));
  paneParts.button.setAttribute("aria-label", busy ? L("Stop", "Durdur") : L("Send", "Gönder"));
  paneParts.button.disabled = state.connection !== "connected" || (session.status === "closed" && !session.parentId);

  const atts = state.attachments.get(session.id) || [];
  paneParts.chips.replaceChildren(
    ...atts.map((att) =>
      h("span", { class: `attachment-chip ${att.state}` },
        icon("paperclip"),
        h("span", { class: "chip-name" }, att.name),
        att.state === "uploading" ? h("span", {}, "…") : null,
        h("button", {
          type: "button",
          class: "chip-remove",
          "aria-label": L("Remove", "Kaldır"),
          onclick: (e) => {
            e.stopPropagation();
            const list = (state.attachments.get(session.id) || []).filter((a) => a.id !== att.id);
            if (list.length === 0) state.attachments.delete(session.id);
            else state.attachments.set(session.id, list);
            render();
          },
        }, "×")
      )
    )
  );

  const transcript = paneParts.transcript;
  const nearEnd = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 120;
  const events = state.events.get(session.id);
  if (!events) {
    transcript.replaceChildren(h("p", { class: "empty" }, L("Loading…", "Yükleniyor…")));
  } else {
    if (transcript.firstChild?.classList?.contains("empty")) transcript.replaceChildren();
    const list = blocks(session, [...events.values()].sort((a, b) => a.seq - b.seq));
    if (list.length === 0) transcript.replaceChildren(h("p", { class: "empty" }, L("Write the first message below.", "İlk mesajı aşağıya yazın.")));
    else reconcile(transcript, list, session.id);
  }
  if (scrollToEnd || nearEnd) transcript.scrollTop = transcript.scrollHeight;
  scrollToEnd = false;
}

function buildPane(sessionId) {
  const title = h("h2", {});
  const status = h("span", { class: "dot" });
  const statusText = h("span", {});
  const header = h("header", { class: "bar" },
    h("button", { class: "icon-button back", "aria-label": L("Back to sessions", "Oturumlara dön"), onclick: () => { location.hash = "#/"; } }, icon("back")),
    h("div", { class: "head-text" }, title, h("div", { class: "connection" }, status, statusText)));
  const flash = h("div", { class: "failure flash", role: "alert", hidden: true });
  const transcript = h("div", { class: "transcript" });
  const chips = h("div", { class: "composer-chips" });
  const fileInput = h("input", {
    type: "file",
    multiple: true,
    // Hidden by class: the page's content policy refuses inline styles.
    hidden: true,
    onchange: () => {
      if (fileInput.files) {
        for (const file of fileInput.files) {
          void uploadAttachment(sessionId, file);
        }
        fileInput.value = "";
      }
    },
  });
  const attachBtn = h("button", {
    type: "button",
    class: "icon-button attach-btn",
    title: L("Attach file", "Dosya ekle"),
    "aria-label": L("Attach file", "Dosya ekle"),
    onclick: () => fileInput.click(),
  }, icon("paperclip"));
  const textarea = h("textarea", {
    rows: 1,
    placeholder: L("Message the agent", "Ajana yazın"),
    "aria-label": L("Message", "Mesaj"),
    oninput: () => {
      state.drafts.set(sessionId, textarea.value);
      grow();
    },
    onkeydown: (event) => {
      // On a phone Return adds a line; the button sends.
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing && !matchMedia("(pointer: coarse)").matches) {
        event.preventDefault();
        submit();
      }
    },
  });
  textarea.value = state.drafts.get(sessionId) ?? "";
  const grow = () => {
    textarea.style.height = "auto";
    textarea.style.height = `${textarea.scrollHeight}px`;
  };
  const button = h("button", { type: "submit", class: "send" });
  const submit = () => {
    const session = state.sessions.get(sessionId);
    if (!session) return;
    if (["running", "starting", "waiting"].includes(session.status)) {
      void stop(sessionId);
      return;
    }
    const atts = state.attachments.get(sessionId) || [];
    if (atts.some((a) => a.state === "uploading")) {
      showFlash(L("Wait for uploads to finish", "Yüklemelerin bitmesini bekleyin"));
      return;
    }
    const text = textarea.value.trim();
    const readyAttachments = atts.filter((a) => a.state === "ready").map((a) => a.path || a.name);
    if (!text && readyAttachments.length === 0) return;
    textarea.value = "";
    grow();
    scrollToEnd = true;
    void send(sessionId, text, readyAttachments);
  };

  const handleDrop = (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (e.dataTransfer?.files?.length) {
      for (const file of e.dataTransfer.files) {
        void uploadAttachment(sessionId, file);
      }
    }
  };
  const handleDragOver = (e) => {
    e.preventDefault();
    e.stopPropagation();
  };
  transcript.addEventListener("dragover", handleDragOver);
  transcript.addEventListener("drop", handleDrop);

  textarea.addEventListener("paste", (e) => {
    if (e.clipboardData?.files?.length) {
      e.preventDefault();
      for (const file of e.clipboardData.files) {
        void uploadAttachment(sessionId, file);
      }
    }
  });

  const inputRow = h("div", { class: "composer-input-row" }, attachBtn, fileInput, textarea, button);
  const composer = h("div", { class: "composer" },
    h("form", {
      onsubmit: (event) => { event.preventDefault(); submit(); },
      ondragover: handleDragOver,
      ondrop: handleDrop,
    }, chips, inputRow));
  requestAnimationFrame(grow);
  return { header, title, status, statusText, flash, transcript, composer, button, chips };
}

// MARK: Start

document.addEventListener("click", (event) => {
  if (state.menu && !event.target.closest(".menu")) {
    state.menu = false;
    render();
  }
});

route();
if (state.key) connect();
