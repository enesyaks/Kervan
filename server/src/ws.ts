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
import { diagnostics } from "./diagnostics.ts";
import { VERSION } from "./version.ts";

export const WS_PATH = "/v1/ws";
const HEARTBEAT_MS = 30_000;
const MAX_FRAME_BYTES = 1024 * 1024;

const sha256 = (value: string) => createHash("sha256").update(value).digest();

// Hashing both sides first gives equal-length buffers, so the compare is constant-time.
export function isAuthorized(header: string | undefined, token: string): boolean {
  if (!header?.startsWith("Bearer ")) return false;
  return timingSafeEqual(sha256(header.slice("Bearer ".length)), sha256(token));
}

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
) {
  switch (message.type) {
    case "ping":
      return send(ws, { type: "pong", id: message.id });
    case "session.create":
      return send(ws, {
        type: "session.created",
        id: message.id,
        session: await sessions.create(message.agent, message.skills, message.mcpServers, {
          orchestrate: message.orchestrate,
          ...(message.budgetUsd ? { budgetUsd: message.budgetUsd } : {}),
          ...(message.projectId ? { projectId: message.projectId } : {}),
        }),
      });
    case "session.changes":
      return send(ws, {
        type: "session.changes.result",
        id: message.id,
        sessionId: message.sessionId,
        changes: await sessions.changes(message.sessionId, message.since),
      });
    case "session.revert":
      await sessions.revert(message.sessionId, message.seq, message.paths);
      return send(ws, { type: "ok", id: message.id });
    case "session.commit":
      await sessions.commit(message.sessionId, message.message);
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
        events: sessions.history(message.sessionId),
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
      sessions.archive(message.sessionId, message.archived);
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

function handleConnection(ws: WebSocket, req: IncomingMessage, sessions: SessionManager, ownPorts: () => number[]): void {
  const remote = req.socket.remoteAddress;
  let greeted = false;
  let unsubscribe: (() => void) | undefined;
  log("info", "ws connected", { remote });

  ws.on("message", async (data, isBinary) => {
    if (isBinary) {
      send(ws, { type: "error", code: "bad_message", message: "binary frames are not supported" });
      return;
    }
    const parsed = parseClientMessage(data.toString());
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
          if (ws.readyState === ws.OPEN) send(ws, event);
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

    try {
      await handleRequest(ws, message, sessions, ownPorts);
    } catch (error) {
      if (!(error instanceof KervanError)) {
        log("error", "request failed", { type: message.type, error: String(error) });
        throw error;
      }
      send(ws, { type: "error", code: error.code, message: error.message, id: message.id });
    }
  });

  ws.on("close", (code) => {
    unsubscribe?.();
    log("info", "ws closed", { remote, code });
  });
}

export function attachWebSocket(
  server: Server,
  token: string,
  sessions: SessionManager,
  heartbeatMs = HEARTBEAT_MS,
  nodeToken?: string,
): WebSocketServer {
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });
  const nodeServer = new WebSocketServer({ noServer: true, maxPayload: MAX_NODE_FRAME_BYTES });
  const tunnels = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024 });
  const ownPorts = () => {
    const address = server.address();
    return address && typeof address === "object" ? [address.port] : [];
  };
  const alive = new WeakSet<WebSocket>();

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    const path = new URL(req.url ?? "/", "http://localhost").pathname;
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
        alive.add(ws);
        ws.on("pong", () => alive.add(ws));
        sessions.nodes!.accept(name, ws, req.headers.host);
      });
      return;
    }
    // A forwarded connection to a port on this machine (the app's port preview).
    if (path === TUNNEL_PATH) {
      const port = Number(new URL(req.url ?? "/", "http://localhost").searchParams.get("port"));
      if (!isAuthorized(req.headers.authorization, token)) {
        rejectUpgrade(socket, 401, "Unauthorized");
        return;
      }
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        rejectUpgrade(socket, 400, "Bad Port");
        return;
      }
      tunnels.handleUpgrade(req, socket, head, (ws) => pipeTunnel(ws, port));
      return;
    }
    if (path !== WS_PATH) {
      rejectUpgrade(socket, 404, "Not Found");
      return;
    }
    if (!isAuthorized(req.headers.authorization, token)) {
      log("warn", "ws auth rejected", { remote: req.socket.remoteAddress });
      rejectUpgrade(socket, 401, "Unauthorized");
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
  });

  wss.on("connection", (ws: WebSocket, req: IncomingMessage) => {
    alive.add(ws);
    ws.on("pong", () => alive.add(ws));
    handleConnection(ws, req, sessions, ownPorts);
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

  server.on("close", () => {
    clearInterval(heartbeat);
    for (const ws of wss.clients) ws.close(1001, "server shutting down");
  });

  return wss;
}
