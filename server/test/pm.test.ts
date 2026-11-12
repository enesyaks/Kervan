import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import type WebSocket from "ws";
import type { SessionManager } from "../src/sessions.ts";
import { HELLO, Inbox, openSocket, opened, send, startServer } from "./helpers.ts";

const git = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@localhost", ...args], { encoding: "utf8" }).trim();

/** A repository with one commit on main. */
function repository(dir: string): void {
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "README.md"), "# proje\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
}

describe("a project's PM", () => {
  let sessions: SessionManager;
  let stop: () => Promise<void>;
  let ws: WebSocket;
  let inbox: Inbox;
  let n = 0;
  const call = async (message: object): Promise<any> => {
    const id = `m${++n}`;
    send(ws, { ...message, id });
    return inbox.waitFor((m) => m.id === id && m.type !== "session.event", 15_000);
  };

  before(async () => {
    let port: number;
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

  it("is a role, given to a project and taken away with project.pm", async () => {
    const project = await sessions.projects!.save({ name: "PM'li" });
    repository(project.path);
    assert.equal((await call({ type: "role.save", role: { id: "pm", name: "PM", agent: "fake", lead: true } })).type, "role.list.result");

    const set = await call({ type: "project.pm", projectId: project.id, pm: { roleId: "pm" } });
    assert.equal(set.type, "project.list.result", set.message);
    // Picking new cards up by itself is on unless asked otherwise; starting its own cards is off.
    assert.deepEqual(set.projects.find((p: any) => p.id === project.id).pm, { roleId: "pm", autoPickup: true, startOwnCases: false });
    assert.equal(sessions.projectPM(project.id)?.role.agent, "fake");

    assert.match((await call({ type: "project.pm", projectId: project.id, pm: { roleId: "yok" } })).message, /no role named 'yok'/);
    assert.match((await call({ type: "project.pm", projectId: "nope", pm: { roleId: "pm" } })).message, /no project 'nope'/);

    const removed = await call({ type: "project.pm", projectId: project.id, pm: null });
    assert.equal(removed.projects.find((p: any) => p.id === project.id).pm, undefined);
  });

  it("stops counting as a PM once its role is deleted", async () => {
    const project = await sessions.projects!.save({ name: "Rolü silinen" });
    repository(project.path);
    await call({ type: "role.save", role: { id: "gecici", name: "Geçici PM", agent: "fake" } });
    await call({ type: "project.pm", projectId: project.id, pm: { roleId: "gecici", autoPickup: false } });
    assert.ok(sessions.projectPM(project.id));
    await call({ type: "role.delete", roleId: "gecici" });
    assert.equal(sessions.projectPM(project.id), undefined);
  });
});
