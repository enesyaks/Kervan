import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { claudeDenyRules, forbiddenPath, parseEnv, parseRedLines, renderEnv, touchesForbidden } from "../src/redlines.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, fakeAgent, openSocket, opened, send, startServer } from "./helpers.ts";

const git = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@localhost", ...args], { encoding: "utf8" }).trim();

function repository(dir: string): void {
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, ".gitignore"), ".env\n.env.local\n");
  writeFileSync(join(dir, ".env.example"), "DATABASE_URL=\nSTRIPE_KEY=\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
}

describe("red lines and env files, as text", () => {
  it("checks red lines: paths inside the project, no exceptions, empty means none", () => {
    assert.deepEqual(parseRedLines({ paths: [" ./.env ", "secrets/", ".env"], rules: ["Never push to main", ""] }), {
      paths: [".env", "secrets"],
      rules: ["Never push to main"],
    });
    assert.equal(parseRedLines({ paths: [], rules: [] }), undefined);
    assert.throws(() => parseRedLines({ paths: ["../outside"] }), /inside the project/);
    assert.throws(() => parseRedLines({ paths: ["/etc/passwd"] }), /inside the project/);
    assert.throws(() => parseRedLines({ paths: ["!.env.example"] }), /exceptions/);
    assert.throws(() => parseRedLines({ paths: "x" }), /list of text/);
  });

  it("matches paths like gitignore: a name anywhere, a folder and what's in it, globs", () => {
    const lines = { paths: [".env", ".env.*", "secrets", "config/*.key"], rules: [] };
    assert.equal(forbiddenPath(lines, ".env"), ".env");
    assert.equal(forbiddenPath(lines, "api/.env"), ".env");
    assert.equal(forbiddenPath(lines, ".env.local"), ".env.*");
    assert.equal(forbiddenPath(lines, "secrets/prod/db.txt"), "secrets");
    assert.equal(forbiddenPath(lines, "config/server.key"), "config/*.key");
    assert.equal(forbiddenPath(lines, "config/deep/server.key"), undefined);
    assert.equal(forbiddenPath(lines, "src/environment.ts"), undefined);
    assert.equal(forbiddenPath(lines, ".envrc"), undefined);
  });

  it("finds a forbidden path in a tool call's title or command", () => {
    const lines = { paths: [".env", ".env.*"], rules: [] };
    assert.equal(touchesForbidden(lines, "cat .env", "/w/app"), ".env");
    assert.equal(touchesForbidden(lines, "Read /w/app/api/.env.local", "/w/app"), "api/.env.local");
    assert.equal(touchesForbidden(lines, `grep -n KEY "./.env"`, "/w/app"), "./.env");
    assert.equal(touchesForbidden(lines, "source .env && npm test", "/w/app"), ".env");
    assert.equal(touchesForbidden(lines, "npm run dev", "/w/app"), undefined);
    assert.equal(touchesForbidden(lines, "Read /elsewhere/.env", "/w/app"), undefined, "outside the folder isn't the project's");
  });

  it("gives Claude Code deny rules for reading, editing and writing them", () => {
    assert.deepEqual(claudeDenyRules({ paths: [".env", "secrets", "config/*.key"], rules: [] }), [
      "Read(**/.env)", "Edit(**/.env)", "Write(**/.env)",
      "Read(**/secrets)", "Edit(**/secrets)", "Write(**/secrets)",
      "Read(**/secrets/**)", "Edit(**/secrets/**)", "Write(**/secrets/**)",
      "Read(./config/*.key)", "Edit(./config/*.key)", "Write(./config/*.key)",
    ]);
    assert.deepEqual(claudeDenyRules(undefined), []);
  });

  it("reads env files and writes them back keeping comments, order and quoting", () => {
    const text = '# db\nDATABASE_URL="postgres://u:p@h/db" # main\nexport DEBUG=1\nNAME=\'a b\'\nOLD=x\n';
    assert.deepEqual(parseEnv(text), [
      { key: "DATABASE_URL", value: "postgres://u:p@h/db" },
      { key: "DEBUG", value: "1" },
      { key: "NAME", value: "a b" },
      { key: "OLD", value: "x" },
    ]);
    const next = renderEnv(text, [
      { key: "DATABASE_URL", value: "postgres://u:p@h/db" },
      { key: "DEBUG", value: "0" },
      { key: "NAME", value: "a b" },
      { key: "NEW", value: 'with "quotes" and #' },
    ]);
    assert.equal(next, '# db\nDATABASE_URL="postgres://u:p@h/db" # main\nexport DEBUG=0\nNAME=\'a b\'\nNEW="with \\"quotes\\" and #"\n');
    assert.deepEqual(parseEnv(next).find((e) => e.key === "NEW"), { key: "NEW", value: 'with "quotes" and #' });
  });
});

describe("red lines and env files in a project", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  const call = async (message: object): Promise<any> => {
    const id = `r${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };
  const create = async (extra: object) => {
    const created = await call({ type: "session.create", agent: "fake", ...extra });
    assert.equal(created.type, "session.created", created.message);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === created.session.id && m.session.status === "idle");
    return created.session;
  };
  const say = async (sessionId: string, text: string) => {
    const id = `p${++n}`;
    const seen = inbox.received.length;
    send(ws, { type: "session.prompt", id, sessionId, text });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end" && inbox.received.indexOf(m) >= seen);
    return inbox.received
      .slice(seen)
      .filter((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "agent_message_chunk")
      .map((m) => m.event.text)
      .join("");
  };
  const notices = (sessionId: string) => sessions.history(sessionId).filter((e) => e.kind === "notice").map((e: any) => e.text as string);

  before(async () => {
    let port: number;
    ({ port, sessions, stop } = await startServer());
    // An agent Kervan takes for Claude Code: the fake one, under claude-agent-acp's name.
    (sessions as any).agents.set("claudeish", { ...fakeAgent, args: [...fakeAgent.args, "claude-agent-acp"] });
    ws = openSocket(port);
    inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
  });

  after(async () => {
    ws.terminate();
    await stop();
  });

  it("saves a project's red lines with it, keeps them when left out, and clears them with empty lists", async () => {
    const saved = await call({ type: "project.save", project: { name: "Çizgili", redLines: { paths: [".env"], rules: ["Never push"] } } });
    const project = saved.projects.find((p: any) => p.name === "Çizgili");
    assert.deepEqual(project.redLines, { paths: [".env"], rules: ["Never push"] });
    await call({ type: "project.save", project: { id: project.id, name: "Çizgili 2" } });
    assert.deepEqual(sessions.projects!.get(project.id)!.redLines, { paths: [".env"], rules: ["Never push"] });
    await call({ type: "project.save", project: { id: project.id, name: "Çizgili 2", redLines: { paths: [], rules: [] } } });
    assert.equal(sessions.projects!.get(project.id)!.redLines, undefined);
    assert.match((await call({ type: "project.save", project: { id: project.id, name: "x", redLines: { paths: ["../x"] } } })).message, /inside the project/);
  });

  it("edits an env file from the app, says what the example lists that's missing, and gives worktrees the values", async () => {
    const project = await sessions.projects!.save({ name: "Envli" });
    repository(project.path);
    writeFileSync(join(project.path, ".env"), "# local\nDATABASE_URL=postgres://old\n");
    const worktree = await create({ projectId: project.id, title: "çalışan" });
    assert.ok(worktree.branch, "the session has a worktree of its own");
    const cwd = (sessions as any).sessions.get(worktree.id).cwd as string;
    assert.equal(readFileSync(join(cwd, ".env"), "utf8"), "# local\nDATABASE_URL=postgres://old\n", "the worktree got the env file git leaves out");

    const shown = await call({ type: "project.env", projectId: project.id });
    assert.equal(shown.type, "project.env.result", shown.message);
    assert.deepEqual([shown.env.file, shown.env.exists, shown.env.files, shown.env.example], [".env", true, [".env", ".env.example"], ".env.example"]);
    assert.deepEqual(shown.env.entries, [{ key: "DATABASE_URL", value: "postgres://old" }]);
    assert.deepEqual(shown.env.missing, ["STRIPE_KEY"]);

    const saved = await call({
      type: "project.env.save",
      projectId: project.id,
      file: ".env",
      entries: [{ key: "DATABASE_URL", value: "postgres://new" }, { key: "STRIPE_KEY", value: "sk_test_1" }],
    });
    assert.deepEqual(saved.env.missing, []);
    assert.equal(readFileSync(join(project.path, ".env"), "utf8"), "# local\nDATABASE_URL=postgres://new\nSTRIPE_KEY=sk_test_1\n");
    assert.equal(readFileSync(join(cwd, ".env"), "utf8"), "# local\nDATABASE_URL=postgres://new\nSTRIPE_KEY=sk_test_1\n", "and the worktree's copy follows");
    assert.ok(notices(worktree.id).some((t) => /The user updated \.env/.test(t)));

    // A new file, and names that aren't env files.
    const local = await call({ type: "project.env.save", projectId: project.id, file: ".env.local", entries: [{ key: "PORT", value: "3001" }] });
    assert.deepEqual([local.env.file, local.env.files], [".env.local", [".env", ".env.example", ".env.local"]]);
    assert.match((await call({ type: "project.env", projectId: project.id, file: "../.env" })).message, /isn't an env file name/);
    assert.match((await call({ type: "project.env.save", projectId: project.id, file: "config.json", entries: [] })).message, /isn't an env file name/);
    assert.match((await call({ type: "project.env.save", projectId: project.id, file: ".env", entries: [{ key: "1BAD", value: "" }] })).message, /isn't a variable name/);
  });

  it("lets an agent ask for env variables by name, which the app then shows as missing until they're filled", async () => {
    const project = await sessions.projects!.save({ name: "İstekli" });
    repository(project.path);
    const session = await create({ projectId: project.id, title: "isteyen" });
    const asked = await say(session.id, `memcall: env_need {"keys":["OPENAI_API_KEY"],"reason":"the summariser calls OpenAI"}`);
    assert.match(asked, /Asked the user for OPENAI_API_KEY/);
    assert.deepEqual(sessions.projects!.get(project.id)!.envRequests!.map((r) => [r.keys, r.reason]), [[["OPENAI_API_KEY"], "the summariser calls OpenAI"]]);
    const shown = await call({ type: "project.env", projectId: project.id });
    assert.deepEqual(shown.env.missing, ["DATABASE_URL", "STRIPE_KEY", "OPENAI_API_KEY"]);
    assert.match(await say(session.id, `memcall: env_need {"keys":["bad key"],"reason":"x"}`), /refused: 'bad key' isn't a variable name/);

    await call({ type: "project.env.save", projectId: project.id, file: ".env", entries: [{ key: "OPENAI_API_KEY", value: "sk-1" }] });
    assert.equal(sessions.projects!.get(project.id)!.envRequests, undefined, "filled, so the request is settled");
  });

  it("tells every agent the red lines and the files it may not touch", async () => {
    const project = await sessions.projects!.save({ name: "Kurallı", redLines: { paths: [".env"], rules: ["Never run database migrations"] } });
    const session = await create({ projectId: project.id, title: "okuyan" });
    const preface = await say(session.id, "prefacecheck");
    assert.match(preface, /Red lines in this project/);
    assert.match(preface, /Never read, open, search, print, copy, move or change these files.*: \.env\./);
    assert.match(preface, /- Never run database migrations/);
    assert.match(preface, /env_need/);
  });

  it("refuses a permission request that touches a forbidden path, before anyone is asked, even on auto-approve", async () => {
    const project = await sessions.projects!.save({ name: "Korunan", redLines: { paths: [".env", ".env.*"], rules: [] } });
    const session = await create({ projectId: project.id, title: "deneyen", autoApprove: true });
    assert.equal(await say(session.id, "askperm: execute cat .env.local"), "permission: no");
    assert.ok(notices(session.id).some((t) => /Red line: refused "cat \.env\.local", which touches \.env\.local/.test(t)));
    assert.ok(!sessions.history(session.id).some((e) => e.kind === "permission_request"), "nobody was asked");
  });

  it("stops the turn when a tool call touches a forbidden path without asking", async () => {
    const project = await sessions.projects!.save({ name: "Bekçili", redLines: { paths: [".env"], rules: [] } });
    const session = await create({ projectId: project.id, title: "kaçak" });
    await say(session.id, "tool: read Read .env");
    assert.ok(notices(session.id).some((t) => /Red line: "Read \.env" touches \.env\. Kervan stopped the turn\./.test(t)));
  });

  it("gives Claude Code the forbidden paths as its own deny rules, and leaves its reads to them", async () => {
    const project = await sessions.projects!.save({ name: "Claude'lu", redLines: { paths: [".env"], rules: [] } });
    const session = await create({ projectId: project.id, title: "claude", agent: "claudeish" });
    const meta = JSON.parse((await say(session.id, "metacheck")).slice("meta: ".length));
    assert.deepEqual(meta.claudeCode.options.settings.permissions.deny, ["Read(**/.env)", "Edit(**/.env)", "Write(**/.env)"]);
    // Claude Code refuses its own read; Kervan doesn't stop the turn for it, only for commands.
    await say(session.id, "tool: read Read .env");
    assert.ok(!notices(session.id).some((t) => /Red line: "Read/.test(t)));
    await say(session.id, "tool: execute cat .env");
    assert.ok(notices(session.id).some((t) => /Red line: "cat \.env" touches \.env/.test(t)));

    const plain = await sessions.projects!.save({ name: "Çizgisiz" });
    const free = await create({ projectId: plain.id, title: "serbest", agent: "claudeish" });
    assert.equal(await say(free.id, "metacheck"), "meta: null", "nothing to deny, nothing sent");
    assert.ok(!existsSync(join(plain.path, ".env")));
  });
});
