// Local server whose only agent is the test fake, for UI work without spending a real agent's quota.
// Usage: node scripts/dev-fake-server.ts   (token: local-dev-token-not-secret, port 7420)
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { log } from "../src/log.ts";
import { AgentCatalog } from "../src/catalog.ts";
import { RoleRegistry } from "../src/roles.ts";
import { LocalAcpRunner, probeAgent } from "../src/runner.ts";
import { createKervanServer } from "../src/server.ts";
import { SessionManager } from "../src/sessions.ts";
import { EventStore } from "../src/store.ts";
import { McpRegistry } from "../src/mcp.ts";
import { SkillLibrary } from "../src/skills.ts";
import { OrchestraHub } from "../src/orchestra.ts";

const dataDir = mkdtempSync(join(tmpdir(), "kervan-dev-data-"));
const skills = new SkillLibrary(join(dataDir, "skills"));
const mcp = new McpRegistry(join(dataDir, "mcp.json"));

const fakeAgent = { name: "Fake", command: process.execPath, args: [join(import.meta.dirname, "../test/fixtures/fake-agent.ts")] };
const runner = new LocalAcpRunner();
const catalog = new AgentCatalog(join(dataDir, "agents.json"), new Map([
    ["claude", { ...fakeAgent, name: "Claude (sahte)" }],
    ["codex", { ...fakeAgent, name: "Codex (sahte)" }],
    ["terminal", {
      name: "Terminal (sahte)",
      command: process.execPath,
      args: [join(import.meta.dirname, "../test/fixtures/fake-terminal.ts")],
      protocol: "pty" as const,
      quietMs: 600,
    }],
]), (definition) => probeAgent(runner, definition));
const roles = new RoleRegistry(join(dataDir, "roles.json"), {
  hasAgent: (id) => catalog.live.has(id),
  hasSkill: (name) => skills.has(name),
  hasMcp: (name) => mcp.has(name),
});
const sessions = new SessionManager(runner, catalog.live, mkdtempSync(join(tmpdir(), "kervan-dev-")), new EventStore(":memory:"), {
  skills,
  mcp,
  catalog,
  roles,
});
const orchestra = new OrchestraHub(join(dataDir, "orchestra.sock"), sessions);
await orchestra.listen();
sessions.useOrchestra(orchestra);
const server = createKervanServer({ token: "local-dev-token-not-secret", sessions, skills });
server.listen(7420, "127.0.0.1", () => log("info", "fake-agent dev server on 127.0.0.1:7420"));
