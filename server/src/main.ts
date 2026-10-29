import { loadAgents } from "./agents.ts";
import { loadConfig } from "./config.ts";
import { log } from "./log.ts";
import { LocalAcpRunner } from "./runner.ts";
import { createKervanServer, VERSION } from "./server.ts";
import { SessionManager } from "./sessions.ts";
import { EventStore } from "./store.ts";
import { McpRegistry } from "./mcp.ts";
import { SkillLibrary } from "./skills.ts";
import { AgentCatalog } from "./catalog.ts";
import { RoleRegistry } from "./roles.ts";
import { probeAgent } from "./runner.ts";
import { join, resolve } from "node:path";
import { OrchestraHub } from "./orchestra.ts";

const config = loadConfig();
const store = new EventStore(join(config.dataDir, "kervan.db"));
const skills = new SkillLibrary(join(config.dataDir, "skills"));
const mcp = new McpRegistry(join(config.dataDir, "mcp.json"));
const runner = new LocalAcpRunner();
const catalog = new AgentCatalog(join(config.dataDir, "agents.json"), loadAgents(config.agentsFile), (definition) =>
  probeAgent(runner, definition),
);
const roles = new RoleRegistry(join(config.dataDir, "roles.json"), {
  hasAgent: (id) => catalog.live.has(id),
  hasSkill: (name) => skills.has(name),
  hasMcp: (name) => mcp.has(name),
});
const sessions = new SessionManager(runner, catalog.live, config.workspacesDir, store, {
  skills,
  mcp,
  catalog,
  roles,
  limits: {
    ...(config.maxHelpers !== undefined ? { maxHelpers: config.maxHelpers } : {}),
    ...(config.helperTurnMinutes !== undefined ? { helperTurnMinutes: config.helperTurnMinutes } : {}),
  },
});
// Absolute: lead agents' MCP bridges run in their own working folders.
const orchestra = new OrchestraHub(resolve(config.dataDir, "orchestra.sock"), sessions);
await orchestra.listen();
sessions.useOrchestra(orchestra);
const server = createKervanServer({ token: config.token, sessions, maxUploadBytes: config.maxUploadBytes, skills });

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
  server.close(() => {
    store.close();
    process.exit(0);
  });
  // Don't hang forever on lingering keep-alive sockets.
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
