import { Containers, findEngine } from "./containers.ts";
import { loadAgents } from "./agents.ts";
import { loadConfig } from "./config.ts";
import { log } from "./log.ts";
import { LocalAcpRunner } from "./runner.ts";
import { createKervanServer, VERSION } from "./server.ts";
import { WebAccess } from "./webaccess.ts";
import { attachBoard } from "./board.ts";
import { attachAlerts } from "./alerts.ts";
import { SessionManager } from "./sessions.ts";
import { EventStore } from "./store.ts";
import { McpRegistry } from "./mcp.ts";
import { SkillLibrary } from "./skills.ts";
import { AgentCatalog } from "./catalog.ts";
import { RoleRegistry } from "./roles.ts";
import { probeAgent } from "./runner.ts";
import { join, resolve } from "node:path";
import { OrchestraHub, orchestraSocketPath } from "./orchestra.ts";
import { NodeHub } from "./nodes.ts";
import { Checkpoints } from "./checkpoints.ts";
import { ProjectRegistry } from "./projects.ts";
import { attachProjectMaps } from "./projectmap.ts";
import { Scheduler } from "./schedules.ts";

const config = loadConfig();
const store = new EventStore(join(config.dataDir, "kervan.db"));
const skills = new SkillLibrary(join(config.dataDir, "skills"));
const mcp = new McpRegistry(join(config.dataDir, "mcp.json"));
// Agents assigned to another machine run on its kervan-node; the rest here.
let sessions: SessionManager;
const nodes = new NodeHub(join(config.dataDir, "nodes.json"), () => {
  sessions?.nodesChanged();
});
nodes.port = config.port;
nodes.watchAddresses();
const runner = nodes.runner(new LocalAcpRunner());
const catalog = new AgentCatalog(
  join(config.dataDir, "agents.json"),
  loadAgents(config.agentsFile),
  (definition) => probeAgent(runner, definition),
  () => nodes.names(),
);
const roles = new RoleRegistry(join(config.dataDir, "roles.json"), {
  hasAgent: (id) => catalog.live.has(id),
  hasSkill: (name) => skills.has(name),
  hasMcp: (name) => mcp.has(name),
});
const projects = new ProjectRegistry(join(config.dataDir, "projects.json"), join(config.workspacesDir, "projects"));
sessions = new SessionManager(runner, catalog.live, config.workspacesDir, store, {
  projects,
  checkpoints: new Checkpoints(process.env.KERVAN_CHECKPOINTS_DIR || resolve(config.dataDir, "checkpoints")),
  nodes,
  skills,
  mcp,
  catalog,
  roles,
  limits: {
    ...(config.maxHelpers !== undefined ? { maxHelpers: config.maxHelpers } : {}),
    ...(config.helperTurnMinutes !== undefined ? { helperTurnMinutes: config.helperTurnMinutes } : {}),
    ...(config.helperIdleMinutes !== undefined ? { helperIdleMinutes: config.helperIdleMinutes } : {}),
  },
});
// Absolute: lead agents' MCP bridges run in their own working folders.
const orchestra = new OrchestraHub(orchestraSocketPath(resolve(process.env.KERVAN_RUN_DIR || config.dataDir, "orchestra.sock")), sessions);
await orchestra.listen();
sessions.useOrchestra(orchestra);
// A lead on a node reaches the same tools through that node's connection.
nodes.orchestra = orchestra;
// Builds in throwaway containers, when this machine has podman or docker.
const containers = new Containers(findEngine());
sessions.containers = containers;
containers.startPruning();
log("info", containers.available ? "builds in containers on" : "no container engine; builds in containers off", { engine: containers.engine });
const scheduler = new Scheduler(join(config.dataDir, "schedules.json"), {
  hasAgent: (id) => catalog.live.has(id),
  hasProject: (id) => projects.get(id) !== undefined,
  remoteNode: (id) => sessions.remoteNode(id),
});
scheduler.onChange = (schedules) => sessions.broadcast({ type: "schedules.updated", schedules });
sessions.scheduler = scheduler;
attachBoard(sessions, join(config.dataDir, "board.json"));
attachProjectMaps(sessions);
attachAlerts(sessions, join(config.dataDir, "alerts.json"));
scheduler.start((task) =>
  sessions.runTask({ agent: task.agent, title: task.title, prompt: task.prompt, scheduleId: task.id, ...(task.projectId ? { projectId: task.projectId } : {}) }),
);
const server = createKervanServer({
  token: config.token,
  sessions,
  maxUploadBytes: config.maxUploadBytes,
  skills,
  ...(config.nodeToken ? { nodeToken: config.nodeToken } : {}),
  web: new WebAccess(join(config.dataDir, "web.json")),
});

// A daily copy of the database; the first one right after start.
const backups = join(config.dataDir, "backups");
const backup = () => {
  try {
    const file = store.backup(backups);
    if (file) log("info", "database backed up", { file });
  } catch (error) {
    log("error", "database backup failed", { error: error instanceof Error ? error.message : String(error) });
  }
};
backup();
setInterval(backup, 60 * 60 * 1000).unref(); // hourly check; writes at most one file a day

server.listen(config.port, config.host, () => {
  log("info", "kervan listening", { host: config.host, port: config.port, version: VERSION });
});

function shutdown(signal: string): void {
  log("info", "shutting down", { signal });
  sessions.closeAll();
  orchestra.close();
  nodes.close();
  void server.shutdown().then(() => {
    store.close();
    process.exit(0);
  });
  // Don't hang forever on a request that never finishes.
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
