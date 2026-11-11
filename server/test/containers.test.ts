import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import { Containers, devcontainerImage, findEngine, validImage } from "../src/containers.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

/** An engine that writes down what it was told, prints a line and exits with a code, so no real engine is needed. */
function fakeEngine(dir: string, body: string): string {
  const path = join(dir, "engine");
  writeFileSync(path, `#!/bin/sh\nprintf '%s\\n' "$@" > "${join(dir, "args")}"\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

describe("building in containers", () => {
  it("takes image names, and nothing an engine would read as an option", () => {
    for (const image of ["node:24", "rust:1", "mcr.microsoft.com/dotnet/sdk:9.0", "ghcr.io/org/img@sha256:abc123", "alpine"]) {
      assert.ok(validImage(image), image);
    }
    for (const image of ["--privileged", "-v", "-v /:/host", "", "node 24", "node:24;rm -rf /", "a".repeat(300)]) {
      assert.ok(!validImage(image), image);
    }
  });

  it("mounts only the session's folder, removes the container, and hands the command over whole", () => {
    const args = Containers.args("kervan-x", "node:24", "/srv/kervan/workspaces/s1", "npm ci && npm run build");
    assert.deepEqual(args.slice(0, 2), ["run", "--rm"]);
    const mounts = args.flatMap((arg, i) => (arg === "-v" ? [args[i + 1]] : []));
    assert.deepEqual(mounts, ["/srv/kervan/workspaces/s1:/work"], "nothing of the machine but the folder");
    assert.ok(!args.includes("--privileged"));
    // The command is one argument to sh inside the container, never parsed by a shell on this machine.
    assert.deepEqual(args.slice(-4), ["node:24", "sh", "-c", "umask 002; npm ci && npm run build"]);
  });

  it("reads the image a devcontainer.json names, comments and all", () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-dc-"));
    mkdirSync(join(dir, ".devcontainer"));
    writeFileSync(join(dir, ".devcontainer", "devcontainer.json"), '{\n  // the toolchain\n  "image": "rust:1",\n  "name": "x"\n}\n');
    assert.equal(devcontainerImage(dir), "rust:1");
    writeFileSync(join(dir, ".devcontainer", "devcontainer.json"), '{ "image": "--privileged" }');
    assert.equal(devcontainerImage(dir), undefined, "an option is not an image");
    assert.equal(devcontainerImage(mkdtempSync(join(tmpdir(), "kervan-dc-"))), undefined);
  });

  it("finds an engine on PATH, and can be turned off", () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-engine-"));
    const podman = fakeEngine(dir, "exit 0");
    const named = join(dir, "podman");
    writeFileSync(named, readFileSync(podman));
    chmodSync(named, 0o755);
    assert.equal(findEngine({ PATH: dir }), named);
    assert.equal(findEngine({ PATH: dir, KERVAN_CONTAINER_ENGINE: "off" }), undefined);
    assert.equal(findEngine({ PATH: "/nonexistent" }), undefined);
  });

  it("reports the exit code and the end of the output", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-engine-"));
    const containers = new Containers(fakeEngine(dir, 'echo "linking app.exe"\nexit 3'));
    const result = await containers.run("node:24", dir, "make windows");
    assert.equal(result.exitCode, 3);
    assert.match(result.output, /linking app\.exe/);
    assert.equal(result.timedOut, false);
    assert.ok(readFileSync(join(dir, "args"), "utf8").split("\n").includes("--rm"));
  });

  it("stops a command that runs too long and says so", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-engine-"));
    const containers = new Containers(fakeEngine(dir, "sleep 5"));
    const result = await containers.run("node:24", dir, "make", 1);
    assert.equal(result.timedOut, true);
  });

  it("refuses an image that isn't one before starting anything", async () => {
    const dir = mkdtempSync(join(tmpdir(), "kervan-engine-"));
    const containers = new Containers(fakeEngine(dir, "exit 0"));
    await assert.rejects(containers.run("--privileged", dir, "id"), /isn't an image name/);
  });
});

describe("building in containers from a session", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  const engineDir = mkdtempSync(join(tmpdir(), "kervan-engine-"));

  let port = 0;

  before(async () => {
    ({ port, sessions, stop } = await startServer());
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

  const create = async (id: string, extra: object) => {
    send(ws, { type: "session.create", id, agent: "fake", ...extra });
    const { session } = await inbox.waitFor((m) => m.type === "session.created" && m.id === id);
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === session.id && m.session.status === "idle");
    return session;
  };

  it("is off without an engine, and says why when asked", async () => {
    sessions.containers = new Containers(undefined);
    const session = await create("b1", {});
    assert.equal(sessions.canBuild(session), false);
    await assert.rejects(sessions.runInContainer(session.id, { command: "make" }), /can't build in containers/);
  });

  it("builds in the project's image, in the session's own folder", async () => {
    sessions.containers = new Containers(fakeEngine(engineDir, 'echo "built"\nexit 0'));
    const project = await sessions.projects!.save({ name: "Masaüstü", buildImage: "mcr.microsoft.com/dotnet/sdk:9.0" });
    const session = await create("b2", { projectId: project.id });
    assert.equal(sessions.canBuild(session), true);

    const answer = await sessions.runInContainer(session.id, { command: "dotnet publish -r win-x64" });
    assert.match(answer, /^exit code 0 \(image mcr\.microsoft\.com\/dotnet\/sdk:9\.0\)\nbuilt/);
    const args = readFileSync(join(engineDir, "args"), "utf8").split("\n");
    assert.ok(args.includes(`${project.path}:/work`), "the project folder, and only it");

    // The agent may name another image for one command; a project without one makes it name it every time.
    await sessions.runInContainer(session.id, { command: "go build", image: "golang:1.25" });
    assert.ok(readFileSync(join(engineDir, "args"), "utf8").split("\n").includes("golang:1.25"));
    const bare = await create("b3", {});
    await assert.rejects(sessions.runInContainer(bare.id, { command: "make" }), /name an image/);
  });

  it("tells the app whether it can build, so the app can offer to set it up", async () => {
    sessions.containers = new Containers(undefined);
    const health = async () => (await (await fetch(`http://127.0.0.1:${port}/health`)).json()) as { containers?: boolean };
    assert.equal((await health()).containers, false);
    const quiet = openSocket(port);
    const heard = new Inbox(quiet);
    await opened(quiet);
    send(quiet, HELLO);
    assert.equal((await heard.waitFor((m) => m.type === "welcome")).server.containers, false);
    quiet.terminate();

    sessions.containers = new Containers(fakeEngine(engineDir, "exit 0"));
    assert.equal((await health()).containers, true, "what the Install button waits for after the restart");
  });

  it("keeps a project's image valid, and lets it be cleared", async () => {
    await assert.rejects(sessions.projects!.save({ name: "Kötü", buildImage: "--privileged" }), /isn't an image name/);
    const project = await sessions.projects!.save({ name: "Değişen", buildImage: "node:24" });
    const cleared = await sessions.projects!.save({ id: project.id, name: "Değişen", buildImage: "" });
    assert.equal(cleared.buildImage, undefined);
    const kept = await sessions.projects!.save({ id: project.id, name: "Değişen 2" });
    assert.equal(kept.buildImage, undefined, "leaving it out of an edit keeps what was there");
  });
});
