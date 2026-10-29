import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { loadConfig } from "../src/config.ts";
import { createKervanServer, VERSION } from "../src/server.ts";

describe("http server", () => {
  const server = createKervanServer();
  let base = "";

  before(async () => {
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(() => new Promise<void>((resolve) => server.close(() => resolve())));

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
  it("uses defaults", () => {
    assert.deepEqual(loadConfig({}), { host: "127.0.0.1", port: 7420, dataDir: "./data" });
  });

  it("rejects an invalid port", () => {
    assert.throws(() => loadConfig({ KERVAN_PORT: "abc" }), /KERVAN_PORT/);
  });
});
