import assert from "node:assert/strict";
import { mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, TEST_TOKEN, openSocket, opened, send, startServer } from "./helpers.ts";

describe("workspace files", () => {
  let base = "";
  let port = 0;
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let sessionId = "";
  const sockets: WebSocket[] = [];
  const auth = { authorization: `Bearer ${TEST_TOKEN}` };

  const files = (path = "", init: RequestInit = {}) =>
    fetch(`${base}/v1/sessions/${sessionId}/files${path ? `/${path}` : ""}`, {
      ...init,
      headers: { ...auth, ...(init.headers as Record<string, string>) },
    });

  before(async () => {
    ({ port, sessions, stop } = await startServer({ maxUploadBytes: 1024 }));
    base = `http://127.0.0.1:${port}`;
    sessionId = (await sessions.create("fake")).id;
  });

  after(async () => {
    for (const ws of sockets) ws.terminate();
    await stop();
  });

  it("uploads, lists and downloads a file", async () => {
    const put = await files("uploads/notlar.txt", { method: "PUT", body: "Kervan yolda" });
    assert.equal(put.status, 201);
    assert.deepEqual(await put.json(), { path: "uploads/notlar.txt", size: 12 });
    assert.equal(readFileSync(join(sessions.workspace(sessionId), "uploads/notlar.txt"), "utf8"), "Kervan yolda");

    const list = await (await files()).json();
    assert.deepEqual(
      list.entries.map((e: any) => [e.path, e.type, e.size]),
      [
        ["uploads", "dir", 0],
        ["uploads/notlar.txt", "file", 12],
      ],
    );
    assert.equal(list.truncated, false);

    const get = await files("uploads/notlar.txt");
    assert.equal(get.status, 200);
    assert.equal(await get.text(), "Kervan yolda");
  });

  it("handles names that need encoding", async () => {
    const path = `uploads/${encodeURIComponent("rapor şubat #1.pdf")}`;
    assert.equal((await files(path, { method: "PUT", body: "x" })).status, 201);
    assert.equal(await (await files(path)).text(), "x");
  });

  it("refuses paths that leave the workspace", async () => {
    for (const path of ["..%2F..%2Fetc%2Fpasswd", "%2Fetc%2Fpasswd", "uploads%2F..%2F..%2Fescape.txt"]) {
      const res = await files(path, { method: "PUT", body: "nope" });
      assert.equal(res.status, 400, path);
    }
  });

  it("refuses to follow a symlink out of the workspace", async () => {
    const outside = join(tmpdir(), `kervan-outside-${process.pid}`);
    mkdirSync(outside, { recursive: true });
    writeFileSync(join(outside, "secret.txt"), "secret");
    symlinkSync(outside, join(sessions.workspace(sessionId), "link"));

    assert.equal((await files("link/secret.txt")).status, 400);
    assert.equal((await files("link/new.txt", { method: "PUT", body: "x" })).status, 400);
  });

  it("rejects uploads over the size limit and keeps no partial file", async () => {
    const res = await files("uploads/big.bin", { method: "PUT", body: "x".repeat(2048) });
    assert.equal(res.status, 413);
    const list = await (await files()).json();
    assert.ok(!list.entries.some((e: any) => e.path.includes("big.bin") || e.path.includes(".kervan-upload-")));
  });

  it("requires the token and a known session", async () => {
    assert.equal((await fetch(`${base}/v1/sessions/${sessionId}/files`)).status, 401);
    assert.equal((await fetch(`${base}/v1/sessions/nope/files`, { headers: auth })).status, 404);
    assert.equal((await files("uploads/missing.txt")).status, 404);
  });

  it("passes attachments to the agent as file links", async () => {
    const ws = openSocket(port);
    sockets.push(ws);
    const inbox = new Inbox(ws);
    await opened(ws);
    send(ws, HELLO);
    await inbox.waitFor((m) => m.type === "welcome");
    await inbox.waitFor((m) => m.type === "session.updated" && m.session.id === sessionId && m.session.status === "idle").catch(() => {});

    send(ws, { type: "session.prompt", id: "p1", sessionId, text: "oku", attachments: ["uploads/notlar.txt"] });
    await inbox.waitFor((m) => m.type === "session.event" && m.sessionId === sessionId && m.event.kind === "turn_end");

    const events = sessions.history(sessionId);
    assert.deepEqual(events.find((e) => e.kind === "user_message"), {
      ...events.find((e) => e.kind === "user_message"),
      attachments: ["uploads/notlar.txt"],
    });
    const reply = events.find((e) => e.kind === "agent_message_chunk");
    assert.ok(reply?.kind === "agent_message_chunk" && reply.text.endsWith("/uploads/notlar.txt"), "agent got a file:// link");

    send(ws, { type: "session.prompt", id: "p2", sessionId, text: "oku", attachments: ["../x"] });
    assert.equal((await inbox.waitFor((m) => m.type === "error" && m.id === "p2")).code, "bad_message");
  });
});

describe("web device file uploads", () => {
  let base = "";
  let sessions: SessionManager;
  let webAccess: any;
  let stop: () => Promise<void>;
  let sessionId = "";
  let deviceToken = "";

  before(async () => {
    let port = 0;
    ({ port, sessions, web: webAccess, stop } = await startServer({ maxUploadBytes: 1024 }));
    base = `http://127.0.0.1:${port}`;
    sessionId = (await sessions.create("fake")).id;
    webAccess.setEnabled(true);
    const { code } = webAccess.startPairing();
    const redeemed = webAccess.redeem(code, "iPhone");
    assert.ok(redeemed);
    deviceToken = redeemed.token;
  });

  after(async () => {
    await stop();
  });

  it("allows paired web device to upload via POST", async () => {
    const res = await fetch(`${base}/v1/sessions/${sessionId}/files?name=test.txt`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${deviceToken}`,
        "content-type": "text/plain",
      },
      body: "hello from phone",
    });
    assert.equal(res.status, 201);
    const data = await res.json();
    assert.equal(data.path, "uploads/test.txt");
    assert.equal(data.size, 16);
    assert.equal(readFileSync(join(sessions.workspace(sessionId), "uploads/test.txt"), "utf8"), "hello from phone");
  });

  it("answers a badly %-encoded file name as a bad request", async () => {
    const res = await fetch(`${base}/v1/sessions/${sessionId}/files`, {
      method: "POST",
      headers: { authorization: `Bearer ${deviceToken}`, "content-disposition": "attachment; filename*=UTF-8''%E0%A4%A.txt" },
      body: "x",
    });
    assert.equal(res.status, 400);
  });

  it("forbids GET operations for paired web device", async () => {
    const res = await fetch(`${base}/v1/sessions/${sessionId}/files`, {
      headers: { authorization: `Bearer ${deviceToken}` },
    });
    assert.equal(res.status, 403);
    assert.deepEqual(await res.json(), { error: "forbidden" });
  });

  it("lets a paired browser add files by name only, never at a path of its choosing", async () => {
    const asDevice = { authorization: `Bearer ${deviceToken}` };
    for (const url of [`files/notes.md`, `files?path=src/app.ts`, `files/uploads/x.txt`]) {
      const res = await fetch(`${base}/v1/sessions/${sessionId}/${url}`, { method: "PUT", headers: asDevice, body: "overwrite" });
      assert.equal(res.status, 403, url);
    }
  });

  it("refuses paths that leave the workspace via query params", async () => {
    for (const name of ["../../etc/passwd", "../escape.txt", "/outside.txt"]) {
      const res = await fetch(`${base}/v1/sessions/${sessionId}/files?name=${encodeURIComponent(name)}`, {
        method: "POST",
        headers: { authorization: `Bearer ${deviceToken}` },
        body: "bad",
      });
      assert.equal(res.status, 400);
    }
  });

  it("rejects unauthorized tokens and blocks after repeated attempts", async () => {
    for (let i = 0; i < 9; i++) {
      const res = await fetch(`${base}/v1/sessions/${sessionId}/files?name=x.txt`, {
        method: "POST",
        headers: { authorization: `Bearer invalid-token-${i}` },
        body: "x",
      });
      assert.equal(res.status, 401);
    }
    const failRes = await fetch(`${base}/v1/sessions/${sessionId}/files?name=x.txt`, {
      method: "POST",
      headers: { authorization: "Bearer invalid-token-10" },
      body: "x",
    });
    assert.equal(failRes.status, 401);

    const blockedRes = await fetch(`${base}/v1/sessions/${sessionId}/files?name=x.txt`, {
      method: "POST",
      headers: { authorization: `Bearer ${deviceToken}` },
      body: "x",
    });
    assert.equal(blockedRes.status, 429);
    assert.deepEqual(await blockedRes.json(), { error: "too_many_attempts" });

    // The app, with the server's own key, is never held back by the limit.
    const fromApp = await fetch(`${base}/v1/sessions/${sessionId}/files`, { headers: { authorization: `Bearer ${TEST_TOKEN}` } });
    assert.equal(fromApp.status, 200);
  });
});

