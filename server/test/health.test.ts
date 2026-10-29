import assert from "node:assert/strict";
import { resolve } from "node:path";
import { after, before, describe, it } from "node:test";
import { loadConfig } from "../src/config.ts";
import { VERSION } from "../src/server.ts";
import { TEST_TOKEN, startServer } from "./helpers.ts";

describe("http server", () => {
  let base = "";
  let stop: () => Promise<void>;

  before(async () => {
    const started = await startServer();
    base = `http://127.0.0.1:${started.port}`;
    stop = started.stop;
  });

  after(() => stop());

  it("GET /health returns ok with version", async () => {
    const res = await fetch(`${base}/health`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, "ok");
    assert.equal(body.version, VERSION);
    assert.equal(typeof body.uptimeSec, "number");
  });

  it("unknown path returns 404", async () => {
    const res = await fetch(`${base}/nope`);
    assert.equal(res.status, 404);
    assert.deepEqual(await res.json(), { error: "not_found" });
  });
});

describe("loadConfig", () => {
  it("uses defaults when the token is set", () => {
    assert.deepEqual(loadConfig({ KERVAN_TOKEN: TEST_TOKEN }), {
      host: "127.0.0.1",
      port: 7420,
      dataDir: "./data",
      workspacesDir: resolve("data/workspaces"),
      token: TEST_TOKEN,
    });
  });

  it("requires a token", () => {
    assert.throws(() => loadConfig({}), /KERVAN_TOKEN/);
    assert.throws(() => loadConfig({ KERVAN_TOKEN: "short" }), /KERVAN_TOKEN/);
  });

  it("rejects an invalid port", () => {
    assert.throws(() => loadConfig({ KERVAN_TOKEN: TEST_TOKEN, KERVAN_PORT: "abc" }), /KERVAN_PORT/);
  });
});
