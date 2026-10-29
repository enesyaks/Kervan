// kervan-node: runs agents for a Kervan hub on this machine.
// KERVAN_HUB_URL (ws://kervan:7420), KERVAN_NODE_TOKEN (the hub's), KERVAN_NODE_NAME (default: host name),
// KERVAN_WORKSPACES_DIR (default ./data/workspaces).
import { hostname } from "node:os";
import { resolve } from "node:path";
import { log } from "./log.ts";
import { NodeAgent } from "./node-agent.ts";
import { NODE_NAME, LOCAL_NODE } from "./nodes.ts";
import { LocalAcpRunner } from "./runner.ts";
import { VERSION } from "./version.ts";

const hubUrl = process.env.KERVAN_HUB_URL ?? "";
const token = process.env.KERVAN_NODE_TOKEN ?? "";
const name = (process.env.KERVAN_NODE_NAME ?? hostname().split(".")[0]).toLowerCase();
const workspacesDir = resolve(process.env.KERVAN_WORKSPACES_DIR ?? "./data/workspaces");

if (!/^wss?:\/\//.test(hubUrl)) throw new Error("KERVAN_HUB_URL must be the hub's ws:// or wss:// address, e.g. ws://kervan:7420");
if (token.length < 16) throw new Error("KERVAN_NODE_TOKEN must be set to the hub's node token");
if (!NODE_NAME.test(name) || name === LOCAL_NODE) throw new Error(`KERVAN_NODE_NAME '${name}' must be lowercase letters, digits or '-', and not 'local'`);

const agent = new NodeAgent({ hubUrl, token, name, workspacesDir, runner: new LocalAcpRunner() });
agent.start();
log("info", "kervan-node started", { name, hub: hubUrl, workspacesDir, version: VERSION });

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    log("info", "kervan-node stopping", { signal });
    agent.stop();
    process.exit(0);
  });
}
