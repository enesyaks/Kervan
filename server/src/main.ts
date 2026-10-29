import { loadConfig } from "./config.ts";
import { log } from "./log.ts";
import { createKervanServer, VERSION } from "./server.ts";

const config = loadConfig();
const server = createKervanServer();

server.listen(config.port, config.host, () => {
  log("info", "kervan listening", { host: config.host, port: config.port, version: VERSION });
});

function shutdown(signal: string): void {
  log("info", "shutting down", { signal });
  server.close(() => process.exit(0));
  // Don't hang forever on lingering keep-alive sockets.
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
