import { defaultAgents } from "./agents.ts";
import { loadConfig } from "./config.ts";
import { log } from "./log.ts";
import { LocalAcpRunner } from "./runner.ts";
import { createKervanServer, VERSION } from "./server.ts";
import { SessionManager } from "./sessions.ts";

const config = loadConfig();
const sessions = new SessionManager(new LocalAcpRunner(), defaultAgents(), config.workspacesDir);
const server = createKervanServer({ token: config.token, sessions });

server.listen(config.port, config.host, () => {
  log("info", "kervan listening", { host: config.host, port: config.port, version: VERSION });
});

function shutdown(signal: string): void {
  log("info", "shutting down", { signal });
  sessions.closeAll();
  server.close(() => process.exit(0));
  // Don't hang forever on lingering keep-alive sockets.
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
