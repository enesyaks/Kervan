import { defaultAgents } from "./agents.ts";
import { loadConfig } from "./config.ts";
import { log } from "./log.ts";
import { LocalAcpRunner } from "./runner.ts";
import { createKervanServer, VERSION } from "./server.ts";
import { SessionManager } from "./sessions.ts";
import { EventStore } from "./store.ts";
import { join } from "node:path";

const config = loadConfig();
const store = new EventStore(join(config.dataDir, "kervan.db"));
const sessions = new SessionManager(new LocalAcpRunner(), defaultAgents(), config.workspacesDir, store);
const server = createKervanServer({ token: config.token, sessions, maxUploadBytes: config.maxUploadBytes });

server.listen(config.port, config.host, () => {
  log("info", "kervan listening", { host: config.host, port: config.port, version: VERSION });
});

function shutdown(signal: string): void {
  log("info", "shutting down", { signal });
  sessions.closeAll();
  server.close(() => {
    store.close();
    process.exit(0);
  });
  // Don't hang forever on lingering keep-alive sockets.
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
