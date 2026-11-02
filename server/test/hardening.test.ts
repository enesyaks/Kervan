import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import WebSocket from "ws";
import { makeDirsInside, openInside, realRootOf } from "../src/files.ts";
import { SkillLibrary } from "../src/skills.ts";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, TEST_TOKEN, opened, openSocket, send, startServer } from "./helpers.ts";

const NODE_TOKEN = "node-token-0123456789";
const folder = () => realpathSync(mkdtempSync(join(tmpdir(), "kervan-hardening-")));

/** Sends bytes as they are, for request lines fetch would never produce; resolves with what comes back. */
function raw(port: number, text: string): Promise<string> {
  return new Promise((resolve, reject) => {
    let answer = "";
    const socket = connect({ host: "127.0.0.1", port }, () => socket.write(text));
    socket.on("data", (chunk) => (answer += chunk.toString()));
    socket.on("close", () => resolve(answer));
    socket.on("error", reject);
  });
}

const closed = (ws: WebSocket) => new Promise<number>((resolve) => ws.on("close", (code) => resolve(code)));

describe("requests that used to take the server down", () => {
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  const auth = { authorization: `Bearer ${TEST_TOKEN}` };
  const healthy = async () => assert.equal((await fetch(`http://127.0.0.1:${port}/health`)).status, 200);

  before(async () => {
    ({ port, sessions, stop } = await startServer({ nodeToken: NODE_TOKEN }));
  });
  after(() => stop());

  for (const target of ["//", "///", "http://[", "//:99999/"]) {
    it(`answers a request for ${target} with 400`, async () => {
      const answer = await raw(port, `GET ${target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);
      assert.match(answer, /^HTTP\/1\.1 400 /);
      await healthy();
    });

    it(`refuses an upgrade to ${target}`, async () => {
      const answer = await raw(port, `GET ${target} HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`);
      assert.match(answer, /^HTTP\/1\.1 400 /);
      await healthy();
    });
  }

  it("answers a badly encoded skill name with 400", async () => {
    const res = await fetch(`http://127.0.0.1:${port}/v1/skills/%E0%A4%A/SKILL.md`, { method: "PUT", headers: auth, body: "x" });
    assert.equal(res.status, 400);
    await healthy();
  });

  it("closes a connection that sends too big a frame, and only that one", async () => {
    const bystander = openSocket(port);
    await opened(bystander);
    const ws = openSocket(port);
    await opened(ws);
    const code = closed(ws);
    ws.send("x".repeat(1024 * 1024 + 1));
    assert.equal(await code, 1009);
    assert.equal(bystander.readyState, WebSocket.OPEN);
    bystander.terminate();
    await healthy();
  });

  const broken = Buffer.from([0xf1, 0x80, 0, 0, 0, 0]); // reserved bits set, which no extension here allows
  const socketsToBreak: [string, () => WebSocket][] = [
    ["the app's", () => openSocket(port)],
    ["a node's", () => new WebSocket(`ws://127.0.0.1:${port}/v1/node`, { headers: { authorization: `Bearer ${NODE_TOKEN}`, "x-kervan-node": "breaker" } })],
    ["a tunnel's", () => new WebSocket(`ws://127.0.0.1:${port}/v1/tunnel?port=9`, { headers: auth })],
  ];
  for (const [name, open] of socketsToBreak) {
    it(`survives a broken frame on ${name} connection`, async () => {
      const ws = open();
      ws.on("error", () => {});
      await opened(ws);
      (ws as unknown as { _socket: NodeJS.WritableStream })._socket.write(broken);
      await closed(ws);
      await healthy();
    });
  }

  it("answers a request that fails unexpectedly with an error", async () => {
    const ws = openSocket(port);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    const list = sessions.list;
    sessions.list = () => {
      throw new Error("disk on fire");
    };
    send(ws, { type: "session.list", id: "boom" });
    const reply = await inbox.waitFor((m) => m.id === "boom");
    sessions.list = list;
    assert.equal(reply.code, "internal");
    assert.ok(!reply.message.includes("disk on fire"), "the reason stays in the log");
    ws.terminate();
    await healthy();
  });
});

describe("a link swapped in a workspace while the server works in it", () => {
  it("refuses a file that turns out to be outside once open", async () => {
    const [root, away] = [folder(), folder()];
    writeFileSync(join(away, "secret"), "secret");
    // What a check-then-open would miss: by the time of the open, the checked path leads out.
    symlinkSync(away, join(root, "swapped"));
    await assert.rejects(openInside(root, join(root, "swapped/secret")), /inside the workspace/);
  });

  it("still opens a file in the workspace, through a link inside it too", async () => {
    const root = folder();
    mkdirSync(join(root, "real"));
    writeFileSync(join(root, "real/file"), "ok");
    symlinkSync(join(root, "real"), join(root, "inner"));
    for (const path of ["real/file", "inner/file"]) {
      const { handle, info } = await openInside(root, join(root, path));
      assert.equal(info.size, 2);
      await handle.close();
    }
  });

  it("doesn't hang on a FIFO", async () => {
    const root = folder();
    execFileSync("mkfifo", [join(root, "pipe")]);
    await assert.rejects(openInside(root, join(root, "pipe")), /not a file/);
  });

  it("doesn't build folders through a link", async () => {
    const [root, away] = [folder(), folder()];
    symlinkSync(away, join(root, "swapped"));
    await assert.rejects(makeDirsInside(root, join(root, "swapped/new")), /inside the workspace/);
    assert.ok(!existsSync(join(away, "new")));
    await makeDirsInside(root, join(root, "a/b"));
    assert.ok(existsSync(join(root, "a/b")));
  });

  it("refuses a workspace swapped for a link, when an agent user could have done it", async () => {
    const [parent, away] = [folder(), folder()];
    symlinkSync(away, join(parent, "workspace"));
    await assert.rejects(realRootOf(join(parent, "workspace"), true), /inside the workspace/);
    assert.equal(await realRootOf(away, true), away);
    assert.equal(await realRootOf(join(parent, "workspace"), false), away, "no second user: a linked folder is just a folder");
  });
});

describe("copying skills into a folder a repository chose", () => {
  const library = () => {
    const skills = new SkillLibrary(folder());
    mkdirSync(skills.dir("s1"));
    writeFileSync(join(skills.dir("s1"), "SKILL.md"), "mine");
    return skills;
  };

  it("refuses a link as the skills folder or on the way to it", async () => {
    for (const link of [".fake/skills", ".fake"]) {
      const [root, away] = [folder(), folder()];
      if (link.includes("/")) mkdirSync(join(root, ".fake"));
      symlinkSync(away, join(root, link));
      await assert.rejects(library().copyInto(["s1"], root, ".fake/skills"), /symbolic link/);
      assert.ok(!existsSync(join(away, "s1")) && !existsSync(join(away, "skills")), link);
    }
  });

  it("refuses a link in place of the skill, or inside an earlier copy", async () => {
    const [root, away] = [folder(), folder()];
    mkdirSync(join(root, ".fake/skills"), { recursive: true });
    symlinkSync(away, join(root, ".fake/skills/s1"));
    await assert.rejects(library().copyInto(["s1"], root, ".fake/skills"), /symbolic link/);

    const [root2, away2] = [folder(), folder()];
    mkdirSync(join(root2, ".fake/skills/s1"), { recursive: true });
    writeFileSync(join(away2, "SKILL.md"), "theirs");
    symlinkSync(join(away2, "SKILL.md"), join(root2, ".fake/skills/s1/SKILL.md"));
    await assert.rejects(library().copyInto(["s1"], root2, ".fake/skills"), /symbolic link/);
    assert.equal(readFileSync(join(away2, "SKILL.md"), "utf8"), "theirs");
  });

  it("copies over an earlier copy and keeps what else is in the folder", async () => {
    const root = folder();
    mkdirSync(join(root, ".fake/skills/s1"), { recursive: true });
    writeFileSync(join(root, ".fake/skills/s1/SKILL.md"), "old");
    writeFileSync(join(root, ".fake/skills/own.md"), "keep");
    await library().copyInto(["s1"], root, ".fake/skills");
    assert.equal(readFileSync(join(root, ".fake/skills/s1/SKILL.md"), "utf8"), "mine");
    assert.equal(readFileSync(join(root, ".fake/skills/own.md"), "utf8"), "keep");
  });
});
