// End-to-end: spawn the real binary and speak MCP over stdio to it.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { startFakeApi, TOKEN } from "./fake_api.js";

const BIN = fileURLToPath(new URL("../bin/anchor-mcp.js", import.meta.url));
let fake;

before(async () => { fake = await startFakeApi(); });
after(async () => { await fake.close(); });

function startServer(env) {
  const child = spawn(process.execPath, [BIN], { env: { PATH: process.env.PATH, ...env }, stdio: ["pipe", "pipe", "pipe"] });
  const rl = createInterface({ input: child.stdout });
  const pending = new Map();
  rl.on("line", (line) => {
    const msg = JSON.parse(line);
    pending.get(msg.id)?.(msg);
  });
  let nextId = 1;
  const request = (method, params) =>
    new Promise((resolve) => {
      const id = nextId++;
      pending.set(id, resolve);
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  const notify = (method) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
  return { child, request, notify };
}

test("full MCP handshake and a deploy over stdio", async () => {
  const { child, request, notify } = startServer({ ANCHOR_URL: fake.url, ANCHOR_TOKEN: TOKEN, ANCHOR_MCP_POLL_MS: "5" });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));

  const init = await request("initialize", {
    protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "stdio-test", version: "0" },
  });
  assert.equal(init.result.serverInfo.name, "anchor");
  notify("notifications/initialized");

  const list = await request("tools/list", {});
  assert.ok(list.result.tools.length >= 10);

  const deploy = await request("tools/call", { name: "deploy", arguments: { project_id: 1, wait: true, timeout_seconds: 30 } });
  assert.equal(deploy.result.isError, false);
  assert.equal(JSON.parse(deploy.result.content[0].text).deployment.status, "running");

  child.stdin.end();
  const code = await new Promise((r) => child.on("close", r));
  assert.equal(code, 0);
  assert.ok(!stderr.includes(TOKEN), "token must never be logged");
});

test("exits with a helpful message when ANCHOR_URL/ANCHOR_TOKEN are missing", async () => {
  const { child } = startServer({});
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  const code = await new Promise((r) => child.on("close", r));
  assert.equal(code, 1);
  assert.match(stderr, /ANCHOR_URL and ANCHOR_TOKEN must be set/);
  assert.match(stderr, /claude mcp add anchor/);
});
