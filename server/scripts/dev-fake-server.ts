// Local server whose only agent is the test fake, for UI work without spending a real agent's quota.
// Usage: node scripts/dev-fake-server.ts   (token: local-dev-token-not-secret, port 7420)
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { log } from "../src/log.ts";
import { LocalAcpRunner } from "../src/runner.ts";
import { createKervanServer } from "../src/server.ts";
import { SessionManager } from "../src/sessions.ts";
import { EventStore } from "../src/store.ts";

const fakeAgent = { command: process.execPath, args: [join(import.meta.dirname, "../test/fixtures/fake-agent.ts")] };
const sessions = new SessionManager(
  new LocalAcpRunner(),
  new Map([["claude", fakeAgent]]),
  mkdtempSync(join(tmpdir(), "kervan-dev-")),
  new EventStore(":memory:"),
);
const server = createKervanServer({ token: "local-dev-token-not-secret", sessions });
server.listen(7420, "127.0.0.1", () => log("info", "fake-agent dev server on 127.0.0.1:7420"));
