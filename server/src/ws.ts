import { createHash, timingSafeEqual } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import { log } from "./log.ts";
import { KervanError, PROTOCOL_VERSION, parseClientMessage, type ClientMessage, type ServerMessage } from "./protocol.ts";
import { MAX_NODE_FRAME_BYTES, NODE_PATH } from "./node-agent.ts";
import { NODE_NAME, LOCAL_NODE } from "./nodes.ts";
import type { SessionManager } from "./sessions.ts";
import { listeningPorts, pipeTunnel, TUNNEL_PATH } from "./tunnel.ts";
import { changesForBrowser, eventForBrowser } from "./webaccess.ts";
import { AttemptLimiter, type WebAccess } from "./webaccess.ts";
import { GitHubAccess } from "./github.ts";
import { AgentLogin } from "./agentlogin.ts";
import { allowedConnection, tailnetOnly } from "./tailnet.ts";
import { AcpRegistry } from "./agentregistry.ts";

/** One per server: the gh sign-in belongs to the user the server runs as. */
const github = new GitHubAccess();
const agentLogin = new AgentLogin();
let acpRegistry: AcpRegistry | undefined;
/** One registry per tools folder (one server in production; tests start several). */
function registryFor(sessions: SessionManager): AcpRegistry {
  const { toolsDir } = requireCatalog(sessions);
  if (acpRegistry?.toolsDir !== toolsDir) acpRegistry = new AcpRegistry(toolsDir);
  return acpRegistry;
}
import { diagnostics } from "./diagnostics.ts";
import { VERSION } from "./version.ts";

export const WS_PATH = "/v1/ws";
const HEARTBEAT_MS = 30_000;
// How long a client gets to answer the close frame when the server shuts down.
const SHUTDOWN_GRACE_MS = 1000;
const MAX_FRAME_BYTES = 1024 * 1024;

const sha256 = (value: string) => createHash("sha256").update(value).digest();

// Hashing both sides first gives equal-length buffers, so the compare is constant-time.
export function isAuthorized(header: string | undefined, token: string): boolean {
  if (!header?.startsWith("Bearer ")) return false;
  return timingSafeEqual(sha256(header.slice("Bearer ".length)), sha256(token));
}

/** Browsers can't set headers on a WebSocket, so the web client offers the key as a subprotocol instead. */
export const WEB_PROTOCOL = "kervan";
const KEY_PROTOCOL = "kervan.key.";

/** The key a browser offered in Sec-WebSocket-Protocol, base64url-encoded after `kervan.key.`. */
export function keyFromProtocols(header: string | undefined): string | undefined {
  const offered = header?.split(",").map((p) => p.trim()).find((p) => p.startsWith(KEY_PROTOCOL));
  return offered ? Buffer.from(offered.slice(KEY_PROTOCOL.length), "base64url").toString("utf8") : undefined;
}

/** Who is on the other end: the app with the server's key, or a paired browser with its own. */
type Client = { kind: "app" } | { kind: "web"; deviceId: string };

/** What a paired browser may ask for: working with sessions. Settings, agents, nodes, files and pairing stay with the app. */
const WEB_ALLOWED = new Set<string>([
  "ping",
  // Projects and their boards, to look at; cards are made and moved from the app.
  "project.list",
  "board.list",
  "session.list",
  "session.history",
  "session.create",
  "session.prompt",
  "session.cancel",
  "session.permission",
  "session.rename",
  "session.archive",
  "session.search",
  "session.config",
  // To read what a session changed; undoing, committing and pull requests stay with the app.
  "session.changes",
]);

/**
 * What a browser hears unasked: its sessions, and the names it shows. A list of what's allowed, so a new broadcast
 * stays with the app until it's added here. Terminals, schedules, nodes and sign-ins are the app's.
 */
const WEB_EVENTS = new Set<ServerMessage["type"]>(["session.updated", "session.event", "agents.updated", "projects.updated", "board.updated"]);

/** The node a catalog request is for, or undefined for this server. */
function targetNode(message: { node?: unknown }): string | undefined {
  const { node } = message;
  if (node === undefined || node === LOCAL_NODE) return undefined;
  if (typeof node !== "string" || !NODE_NAME.test(node)) throw new KervanError("bad_message", "'node' must be a node's name");
  return node;
}

const nodeAgentSuffix = (node: string) => `-${node}`;

function rejectUpgrade(socket: Duplex, status: number, reason: string): void {
  socket.end(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

function send(ws: WebSocket, message: ServerMessage): void {
  ws.send(JSON.stringify(message));
}

function requireCatalog(sessions: SessionManager) {
  if (!sessions.catalog) throw new KervanError("bad_message", "agents can't be edited on this server");
  return sessions.catalog;
}

function agentList(id: string, sessions: SessionManager): ServerMessage {
  const catalog = requireCatalog(sessions);
  return { type: "agent.list.result", id, agents: catalog.list(), nodes: catalog.nodes() };
}

function requireNodes(sessions: SessionManager) {
  if (!sessions.nodes) throw new KervanError("bad_message", "this server doesn't take nodes");
  return sessions.nodes;
}

function requireRoles(sessions: SessionManager) {
  if (!sessions.roles) throw new KervanError("bad_message", "this server has no roles");
  return sessions.roles;
}

function requireMcp(sessions: SessionManager) {
  if (!sessions.mcp) throw new KervanError("bad_message", "this server has no MCP registry");
  return sessions.mcp;
}

function requireAlerts(sessions: SessionManager) {
  if (!sessions.alerts) throw new KervanError("bad_message", "this server has no alerts");
  return sessions.alerts;
}

function requireBoard(sessions: SessionManager) {
  if (!sessions.board) throw new KervanError("bad_message", "this server has no task boards");
  return sessions.board;
}

function requireProjects(sessions: SessionManager) {
  if (!sessions.projects) throw new KervanError("bad_message", "this server has no projects");
  return sessions.projects;
}

function requireScheduler(sessions: SessionManager) {
  if (!sessions.scheduler) throw new KervanError("bad_message", "this server runs no scheduled tasks");
  return sessions.scheduler;
}

/** The folder of a session on this server; terminals don't reach nodes. */
function localFolder(sessions: SessionManager, sessionId: string): string {
  const location = sessions.location(sessionId);
  if (!("path" in location)) throw new KervanError("bad_message", "a terminal can only open for agents on this server, not on a node");
  return location.path;
}

async function handleRequest(
  ws: WebSocket,
  message: Exclude<ClientMessage, { type: "hello" }>,
  sessions: SessionManager,
  ownPorts: () => number[],
  web: WebAccess | undefined,
  browser: boolean,
) {
  const requireWeb = () => {
    if (!web) throw new KervanError("bad_message", "this server has no web client");
    return web;
  };
  switch (message.type) {
    case "alerts.get":
      return send(ws, { type: "alerts.result", id: message.id, alerts: requireAlerts(sessions).view() });
    case "alerts.save":
      requireAlerts(sessions).save(message.alerts);
      return send(ws, { type: "alerts.result", id: message.id, alerts: requireAlerts(sessions).view() });
    case "alerts.test":
      await requireAlerts(sessions).test();
      return send(ws, { type: "ok", id: message.id });
    case "board.list":
      return send(ws, { type: "board.result", id: message.id, projectId: message.projectId, cards: requireBoard(sessions).list(message.projectId) });
    case "card.save": {
      const card = requireBoard(sessions).save(message.card);
      return send(ws, { type: "board.result", id: message.id, projectId: card.projectId, cards: requireBoard(sessions).list(card.projectId) });
    }
    case "card.move":
      await requireBoard(sessions).move(message.cardId, message.column);
      return send(ws, { type: "ok", id: message.id });
    case "card.delete":
      requireBoard(sessions).remove(message.cardId);
      return send(ws, { type: "ok", id: message.id });
    case "github.status":
      return send(ws, { type: "github.status.result", id: message.id, github: await github.status() });
    case "github.connect": {
      const device = await github.connect(async (error) => {
        sessions.broadcast({ type: "github.updated", github: await github.status(), ...(error ? { error } : {}) });
      });
      return send(ws, { type: "github.code", id: message.id, ...device });
    }
    case "agent.login": {
      const agent = message.agent;
      const started = await agentLogin.start(agent, (error) => {
        // The login is on disk now (or not); the agent list says so, and the app hears which way it went.
        sessions.agentsChanged();
        const signedIn = sessions.catalog?.list().find((a) => a.id === agent)?.signedIn;
        sessions.broadcast({ type: "agent.login.finished", agent, signedIn: !error && signedIn !== false, ...(error ? { error } : {}) });
      });
      return send(ws, { type: "agent.login.started", id: message.id, ...started });
    }
    case "agent.login.code":
      agentLogin.submitCode(message.agent, message.code);
      return send(ws, { type: "ok", id: message.id });
    case "agent.login.cancel":
      agentLogin.cancel(message.agent);
      return send(ws, { type: "ok", id: message.id });
    case "agent.logout":
      await agentLogin.signOut(message.agent);
      sessions.agentsChanged();
      return send(ws, agentList(message.id, sessions));
    case "agent.registry": {
      const catalog = requireCatalog(sessions);
      const node = targetNode(message);
      if (node) {
        const suffix = nodeAgentSuffix(node);
        const added = catalog.list().filter((agent) => agent.node === node).map((agent) => (agent.id.endsWith(suffix) ? agent.id.slice(0, -suffix.length) : agent.id));
        const { agents, ollama } = await requireNodes(sessions).offerAgents(node, added);
        return send(ws, { type: "agent.registry.result", id: message.id, agents, ollama });
      }
      const registry = registryFor(sessions);
      const added = new Set(catalog.list().filter((agent) => agent.node === LOCAL_NODE).map((agent) => agent.id));
      const [agents, ollama] = await Promise.all([registry.offer(added), registry.ollama()]);
      return send(ws, { type: "agent.registry.result", id: message.id, agents, ollama });
    }
    case "agent.install": {
      const catalog = requireCatalog(sessions);
      const model = (message as { ollamaModel?: unknown }).ollamaModel;
      if (model !== undefined && typeof model !== "string") throw new KervanError("bad_message", "'ollamaModel' must be a string");
      const request = { agentId: message.agentId, ...(model ? { ollamaModel: model } : {}) };
      const node = targetNode(message);
      if (node) {
        const installed = await requireNodes(sessions).installAgent(node, request);
        // Its own id: the same agent can be on this server and on any node, each set up for its machine.
        await catalog.save({ ...installed, id: `${installed.id}${nodeAgentSuffix(node)}`, node });
      } else {
        await catalog.save(await registryFor(sessions).install(request));
      }
      sessions.agentsChanged();
      return send(ws, agentList(message.id, sessions));
    }
    case "github.disconnect": {
      await github.disconnect();
      const status = await github.status();
      sessions.broadcast({ type: "github.updated", github: status });
      return send(ws, { type: "github.status.result", id: message.id, github: status });
    }
    case "web.status":
      return send(ws, { type: "web.status.result", id: message.id, web: requireWeb().status() });
    case "web.enable":
      requireWeb().setEnabled(message.enabled);
      return send(ws, { type: "web.status.result", id: message.id, web: requireWeb().status() });
    case "web.pair":
      return send(ws, { type: "web.paired", id: message.id, ...requireWeb().startPairing() });
    case "web.revoke":
      requireWeb().revoke(message.deviceId);
      return send(ws, { type: "web.status.result", id: message.id, web: requireWeb().status() });
    case "ping":
      return send(ws, { type: "pong", id: message.id });
    case "session.create":
      return send(ws, {
        type: "session.created",
        id: message.id,
        session: await sessions.create(message.agent, message.skills, message.mcpServers, {
          orchestrate: message.orchestrate,
          ...(message.split ? { split: true } : {}),
          ...(message.budgetUsd ? { budgetUsd: message.budgetUsd } : {}),
          ...(message.projectId ? { projectId: message.projectId } : {}),
          ...(message.shared ? { shared: true } : {}),
        }),
      });
    case "session.changes": {
      const changes = await sessions.changes(message.sessionId, message.since);
      return send(ws, {
        type: "session.changes.result",
        id: message.id,
        sessionId: message.sessionId,
        changes: browser ? changesForBrowser(changes) : changes,
      });
    }
    case "session.revert":
      await sessions.revert(message.sessionId, message.seq, message.paths);
      return send(ws, { type: "ok", id: message.id });
    case "session.commit":
      await sessions.commit(message.sessionId, message.message);
      return send(ws, { type: "ok", id: message.id });
    case "session.review":
      await sessions.review(message.sessionId, message.agent);
      return send(ws, { type: "ok", id: message.id });
    case "session.pullRequest":
      return send(ws, {
        type: "session.pullRequest.result",
        id: message.id,
        sessionId: message.sessionId,
        pullRequest: await sessions.pullRequest(message.sessionId, message.title, message.body ?? ""),
      });
    case "project.list":
      return send(ws, { type: "project.list.result", id: message.id, projects: sessions.projects?.list() ?? [] });
    case "project.save":
      await requireProjects(sessions).save(message.project);
      sessions.broadcast({ type: "projects.updated", projects: requireProjects(sessions).list() });
      return send(ws, { type: "project.list.result", id: message.id, projects: requireProjects(sessions).list() });
    case "project.delete":
      requireProjects(sessions).remove(message.projectId);
      sessions.broadcast({ type: "projects.updated", projects: requireProjects(sessions).list() });
      return send(ws, { type: "project.list.result", id: message.id, projects: requireProjects(sessions).list() });
    case "schedule.list":
      return send(ws, { type: "schedule.list.result", id: message.id, schedules: sessions.scheduler?.list() ?? [] });
    case "schedule.save":
      requireScheduler(sessions).save(message.schedule);
      return send(ws, { type: "schedule.list.result", id: message.id, schedules: requireScheduler(sessions).list() });
    case "schedule.delete":
      requireScheduler(sessions).remove(message.scheduleId);
      return send(ws, { type: "schedule.list.result", id: message.id, schedules: requireScheduler(sessions).list() });
    case "schedule.run":
      await requireScheduler(sessions).runNow(message.scheduleId);
      return send(ws, { type: "schedule.list.result", id: message.id, schedules: requireScheduler(sessions).list() });
    case "usage.report":
      return send(ws, { type: "usage.report.result", id: message.id, report: sessions.usageReport(message.days, message.timeZone) });
    case "terminal.open": {
      const { terminalId, backlog } = sessions.terminals.open(message.sessionId, localFolder(sessions, message.sessionId));
      return send(ws, { type: "terminal.opened", id: message.id, terminalId, sessionId: message.sessionId, backlog });
    }
    case "terminal.input":
      sessions.terminals.input(message.terminalId, message.data);
      return send(ws, { type: "ok", id: message.id });
    case "terminal.close":
      sessions.terminals.close(message.terminalId);
      return send(ws, { type: "ok", id: message.id });
    case "diagnostics":
      return send(ws, { type: "diagnostics.result", id: message.id, report: diagnostics(sessions) });
    case "port.list":
      return send(ws, { type: "port.list.result", id: message.id, ports: await listeningPorts(ownPorts()) });
    case "session.config":
      await sessions.setConfig(message.sessionId, message.configId, message.value);
      return send(ws, { type: "ok", id: message.id });
    case "node.list":
      return send(ws, { type: "node.list.result", id: message.id, nodes: sessions.nodes?.list() ?? [], hubAddresses: sessions.nodes?.addresses() ?? [] });
    case "node.invite": {
      const { code, expiresAt } = requireNodes(sessions).invite(message.name);
      return send(ws, { type: "node.invited", id: message.id, name: message.name, code, expiresAt });
    }
    case "node.remove":
      requireNodes(sessions).remove(message.name);
      return send(ws, { type: "node.list.result", id: message.id, nodes: requireNodes(sessions).list(), hubAddresses: requireNodes(sessions).addresses() });
    case "session.list":
      return send(ws, { type: "session.list.result", id: message.id, sessions: sessions.list() });
    case "session.history":
      return send(ws, {
        type: "session.history.result",
        id: message.id,
        sessionId: message.sessionId,
        events: browser ? sessions.history(message.sessionId).map(eventForBrowser) : sessions.history(message.sessionId),
      });
    case "session.prompt":
      sessions.prompt(message.sessionId, message.text, message.attachments);
      return send(ws, { type: "ok", id: message.id });
    case "session.cancel":
      await sessions.cancel(message.sessionId);
      return send(ws, { type: "ok", id: message.id });
    case "session.permission":
      sessions.respond(message.sessionId, message.requestId, message.optionId);
      return send(ws, { type: "ok", id: message.id });
    case "session.rename":
      sessions.rename(message.sessionId, message.title);
      return send(ws, { type: "ok", id: message.id });
    case "session.archive":
      await sessions.archive(message.sessionId, message.archived, message.removeWorktree ?? false);
      return send(ws, { type: "ok", id: message.id });
    case "agent.list":
      return send(ws, agentList(message.id, sessions));
    case "agent.save":
      await requireCatalog(sessions).save(message.agent);
      sessions.agentsChanged();
      return send(ws, agentList(message.id, sessions));
    case "agent.delete":
      requireCatalog(sessions).remove(message.agentId);
      sessions.agentsChanged();
      return send(ws, agentList(message.id, sessions));
    case "role.list":
      return send(ws, { type: "role.list.result", id: message.id, roles: requireRoles(sessions).list() });
    case "role.save":
      requireRoles(sessions).save(message.role);
      return send(ws, { type: "role.list.result", id: message.id, roles: requireRoles(sessions).list() });
    case "role.delete":
      requireRoles(sessions).remove(message.roleId);
      return send(ws, { type: "role.list.result", id: message.id, roles: requireRoles(sessions).list() });
    case "team.create":
      return send(ws, { type: "team.created", id: message.id, team: await sessions.createTeam(message.title, message.roles) });
    case "team.list":
      return send(ws, { type: "team.list.result", id: message.id, teams: sessions.listTeams() });
    case "mcp.list":
      return send(ws, { type: "mcp.list.result", id: message.id, servers: requireMcp(sessions).list() });
    case "mcp.save":
      requireMcp(sessions).save(message.server);
      return send(ws, { type: "mcp.list.result", id: message.id, servers: requireMcp(sessions).list() });
    case "mcp.delete":
      requireMcp(sessions).remove(message.name);
      return send(ws, { type: "mcp.list.result", id: message.id, servers: requireMcp(sessions).list() });
    case "session.search":
      return send(ws, {
        type: "session.search.result",
        id: message.id,
        hits: sessions.search(message.query).map(({ sessionId, seq, role, snippet }) => ({ sessionId, seq, role, snippet })),
      });
  }
}

function peekField(raw: string, field: "type" | "id"): string | undefined {
  try {
    const value = (JSON.parse(raw) as Record<string, unknown> | null)?.[field];
    return typeof value === "string" ? value : undefined;
  } catch {
    return undefined;
  }
}
const peekType = (raw: string) => peekField(raw, "type");
const peekId = (raw: string) => peekField(raw, "id");

function handleConnection(
  ws: WebSocket,
  req: IncomingMessage,
  sessions: SessionManager,
  ownPorts: () => number[],
  client: Client,
  web: WebAccess | undefined,
): void {
  const remote = req.socket.remoteAddress;
  let greeted = false;
  let unsubscribe: (() => void) | undefined;
  log("info", "ws connected", { remote });

  ws.on("message", async (data, isBinary) => {
    if (isBinary) {
      send(ws, { type: "error", code: "bad_message", message: "binary frames are not supported" });
      return;
    }
    const raw = data.toString();
    // A browser hears "forbidden" for what it may not ask, before the shape of the request is checked, so the
    // errors don't tell it how those requests are built.
    if (client.kind === "web") {
      const type = peekType(raw);
      if (type !== undefined && type !== "hello" && !WEB_ALLOWED.has(type)) {
        const id = peekId(raw);
        send(ws, { type: "error", code: "forbidden", message: "only the Kervan app can do that", ...(id ? { id } : {}) });
        return;
      }
    }
    const parsed = parseClientMessage(raw);
    if (!parsed.ok) {
      send(ws, { type: "error", code: parsed.code, message: parsed.message, ...(parsed.id ? { id: parsed.id } : {}) });
      return;
    }

    const message = parsed.message;
    if (message.type === "hello") {
      if (message.protocol !== PROTOCOL_VERSION) {
        send(ws, {
          type: "error",
          code: "unsupported_protocol",
          message: `server speaks protocol ${PROTOCOL_VERSION}, client sent ${message.protocol}`,
        });
        ws.close(4000, "unsupported protocol");
        return;
      }
      if (!greeted) {
        greeted = true;
        unsubscribe = sessions.subscribe((event) => {
          if (client.kind === "web" && !WEB_EVENTS.has(event.type)) return;
          if (ws.readyState !== ws.OPEN) return;
          send(ws, client.kind === "web" && event.type === "session.event" ? { ...event, event: eventForBrowser(event.event) } : event);
        });
      }
      log("info", "ws hello", { remote, client: message.client });
      send(ws, {
        type: "welcome",
        protocol: PROTOCOL_VERSION,
        server: { name: "kervan", version: VERSION },
        agents: sessions.agentKinds,
        agentDetails: sessions.agentDetails,
      });
      return;
    }

    if (!greeted) {
      send(ws, { type: "error", code: "hello_required", message: "send 'hello' first", id: message.id });
      return;
    }

    if (client.kind === "web" && !WEB_ALLOWED.has(message.type)) {
      send(ws, { type: "error", code: "forbidden", message: "only the Kervan app can do that", id: message.id });
      return;
    }

    try {
      await handleRequest(ws, message, sessions, ownPorts, web, client.kind === "web");
    } catch (error) {
      if (!(error instanceof KervanError)) {
        // This handler's promise has no one to catch it: thrown on, one failed request would end every session.
        log("error", "request failed", { type: message.type, error: String(error) });
        send(ws, { type: "error", code: "internal", message: "the server couldn't do that; its log has the details", id: message.id });
        return;
      }
      send(ws, { type: "error", code: error.code, message: error.message, id: message.id });
    }
  });

  ws.on("close", (code) => {
    unsubscribe?.();
    log("info", "ws closed", { remote, code });
  });
}

/** The request's URL, or undefined for one that doesn't parse: `GET //` is a valid request line but no valid URL. */
export function requestUrl(req: IncomingMessage): URL | undefined {
  try {
    return new URL(req.url ?? "/", "http://localhost");
  } catch {
    return undefined;
  }
}

/** A frame over the limit or a broken one ends up here; without a listener it would take the whole server down. */
function closeOnError(ws: WebSocket, remote: string | undefined): void {
  ws.on("error", (error) => log("warn", "ws error", { remote, error: error.message }));
}

export function attachWebSocket(
  server: Server,
  token: string,
  sessions: SessionManager,
  heartbeatMs = HEARTBEAT_MS,
  nodeToken?: string,
  web?: WebAccess,
  limiter: AttemptLimiter = new AttemptLimiter(),
): () => void {
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: MAX_FRAME_BYTES,
    // Answer with the plain protocol name only; the key one is never echoed back.
    handleProtocols: (protocols) => (protocols.has(WEB_PROTOCOL) ? WEB_PROTOCOL : false),
  });
  const nodeServer = new WebSocketServer({ noServer: true, maxPayload: MAX_NODE_FRAME_BYTES });
  const tunnels = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024 });
  const ownPorts = () => {
    const address = server.address();
    return address && typeof address === "object" ? [address.port] : [];
  };
  const alive = new WeakSet<WebSocket>();

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    if (tailnetOnly() && !allowedConnection(req.socket.remoteAddress, req.socket.localAddress)) {
      rejectUpgrade(socket, 403, "Tailscale Only");
      return;
    }
    const url = requestUrl(req);
    if (!url) {
      rejectUpgrade(socket, 400, "Bad Request");
      return;
    }
    const path = url.pathname;
    // Nodes use their own token, so a leaked node token can't drive the app's API.
    if (path === NODE_PATH && sessions.nodes) {
      const name = req.headers["x-kervan-node"];
      const bearer = req.headers.authorization?.startsWith("Bearer ") ? req.headers.authorization.slice(7) : "";
      // A node's own token from joining, or the shared KERVAN_NODE_TOKEN for nodes set up by hand.
      const allowed =
        (typeof name === "string" && sessions.nodes.authorize(name, bearer)) ||
        (nodeToken !== undefined && isAuthorized(req.headers.authorization, nodeToken));
      if (!allowed) {
        log("warn", "node auth rejected", { remote: req.socket.remoteAddress });
        rejectUpgrade(socket, 401, "Unauthorized");
        return;
      }
      if (typeof name !== "string" || !NODE_NAME.test(name) || name === LOCAL_NODE) {
        rejectUpgrade(socket, 400, "Bad Node Name");
        return;
      }
      nodeServer.handleUpgrade(req, socket, head, (ws) => {
        closeOnError(ws, req.socket.remoteAddress);
        alive.add(ws);
        ws.on("pong", () => alive.add(ws));
        sessions.nodes!.accept(name, ws, req.headers.host);
      });
      return;
    }
    // A forwarded connection to a port on this machine (the app's port preview).
    if (path === TUNNEL_PATH) {
      const port = Number(url.searchParams.get("port"));
      if (!isAuthorized(req.headers.authorization, token)) {
        rejectUpgrade(socket, 401, "Unauthorized");
        return;
      }
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        rejectUpgrade(socket, 400, "Bad Port");
        return;
      }
      tunnels.handleUpgrade(req, socket, head, (ws) => {
        closeOnError(ws, req.socket.remoteAddress);
        pipeTunnel(ws, port);
      });
      return;
    }
    if (path !== WS_PATH) {
      rejectUpgrade(socket, 404, "Not Found");
      return;
    }
    // The app signs in with the server's key; a browser only ever with a paired device's own key.
    let client: Client;
    const remote = req.socket.remoteAddress;
    if (isAuthorized(req.headers.authorization, token)) {
      client = { kind: "app" };
    } else {
      const key = keyFromProtocols(req.headers["sec-websocket-protocol"]);
      if (key !== undefined && limiter.blocked(remote)) {
        rejectUpgrade(socket, 429, "Too Many Requests");
        return;
      }
      const device = key !== undefined ? web?.authenticate(key) : undefined;
      if (!device) {
        if (key !== undefined) limiter.fail(remote);
        log("warn", "ws auth rejected", { remote });
        rejectUpgrade(socket, 401, "Unauthorized");
        return;
      }
      client = { kind: "web", deviceId: device.id };
      log("info", "web device connected", { remote, device: device.name });
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      if (client.kind === "web") webClients.set(ws, client.deviceId);
      wss.emit("connection", ws, req, client);
    });
  });

  // A revoked device (or every device, when web access is turned off) is cut off at once.
  const webClients = new Map<WebSocket, string>();
  web?.onRevoke((deviceId) => {
    for (const [ws, owner] of webClients) {
      if (deviceId === null || owner === deviceId) ws.close(4001, "web access ended");
    }
  });

  wss.on("connection", (ws: WebSocket, req: IncomingMessage, client: Client = { kind: "app" }) => {
    closeOnError(ws, req.socket.remoteAddress);
    ws.on("close", () => webClients.delete(ws));
    alive.add(ws);
    ws.on("pong", () => alive.add(ws));
    handleConnection(ws, req, sessions, ownPorts, client, web);
  });

  // Drop clients that missed a whole heartbeat round (sleeping laptop, dead network).
  const heartbeat = setInterval(() => {
    for (const ws of [...wss.clients, ...nodeServer.clients]) {
      if (!alive.has(ws)) {
        ws.terminate();
        continue;
      }
      alive.delete(ws);
      ws.ping();
    }
  }, heartbeatMs);
  heartbeat.unref();

  server.on("close", () => clearInterval(heartbeat));

  // Ends every upgraded connection; the HTTP server's close waits for them, and for a dead client would wait 30s more.
  return () => {
    const open = [...wss.clients, ...nodeServer.clients, ...tunnels.clients];
    for (const ws of open) ws.close(1001, "server shutting down");
    setTimeout(() => {
      for (const ws of open) ws.terminate();
    }, SHUTDOWN_GRACE_MS).unref();
  };
}
