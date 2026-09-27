import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { AnchorApi } from "../src/api.js";
import { McpServer } from "../src/server.js";
import { tools } from "../src/tools.js";
import { startFakeApi, TOKEN } from "./fake_api.js";

let fake;
let server;
let sent;

before(async () => { fake = await startFakeApi(); });
after(async () => { await fake.close(); });

beforeEach(() => {
  sent = [];
  fake.state.requests.length = 0;
  fake.state.deployments.clear();
  const api = new AnchorApi({ baseUrl: fake.url, token: TOKEN });
  server = new McpServer({ api, pollIntervalMs: 1, sleep: async () => {} }, (m) => sent.push(m));
});

async function rpc(method, params, id = 1) {
  await server.handleLine(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  return sent.at(-1);
}

async function call(name, args) {
  const res = await rpc("tools/call", { name, arguments: args });
  assert.ok(res.result, `expected result, got ${JSON.stringify(res)}`);
  const text = res.result.content[0].text;
  return { isError: res.result.isError, text, data: res.result.isError ? null : JSON.parse(text) };
}

test("initialize negotiates protocol version and advertises tools", async () => {
  const res = await rpc("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "t", version: "1" } });
  assert.equal(res.result.protocolVersion, "2025-03-26");
  assert.deepEqual(res.result.capabilities, { tools: { listChanged: false } });
  assert.equal(res.result.serverInfo.name, "anchor");
  assert.match(res.result.instructions, /deploy/);

  const unknown = await rpc("initialize", { protocolVersion: "1999-01-01" });
  assert.equal(unknown.result.protocolVersion, "2025-06-18");
});

test("notifications get no response; ping returns {}", async () => {
  await server.handleLine(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }));
  assert.equal(sent.length, 0);
  assert.deepEqual((await rpc("ping")).result, {});
});

test("tools/list exposes every required tool with schemas and descriptions", async () => {
  const res = await rpc("tools/list", {});
  const names = res.result.tools.map((t) => t.name);
  for (const n of ["list_projects", "get_project", "deploy", "get_deployment", "get_logs", "cancel_deployment",
                   "rollback", "list_secrets", "set_secret", "get_analysis"]) {
    assert.ok(names.includes(n), `missing ${n}`);
  }
  for (const t of res.result.tools) {
    assert.equal(t.inputSchema.type, "object");
    assert.ok(t.description.length > 40, `${t.name} needs a real description`);
    assert.equal(typeof t.annotations.readOnlyHint, "boolean");
  }
  assert.equal(tools.find((t) => t.name === "rollback").annotations.destructiveHint, true);
});

test("unknown method and malformed JSON return JSON-RPC errors", async () => {
  assert.equal((await rpc("nope")).error.code, -32601);
  await server.handleLine("{not json");
  assert.equal(sent.at(-1).error.code, -32700);
  assert.equal((await rpc("tools/call", { name: "no_such_tool", arguments: {} })).error.code, -32602);
});

test("list_projects and get_project call the API with the bearer token", async () => {
  const { data } = await call("list_projects", {});
  assert.equal(data.projects.length, 2);
  const { data: one } = await call("get_project", { project_id: "1" }); // string id is coerced
  assert.equal(one.project.name, "shop");
  assert.ok(fake.state.requests.every((r) => r.auth === `Bearer ${TOKEN}`));
});

test("argument validation returns a tool error without calling the API", async () => {
  const res = await call("get_project", {});
  assert.equal(res.isError, true);
  assert.match(res.text, /project_id is required/);
  const bad = await call("get_project", { project_id: 1, extra: true });
  assert.match(bad.text, /extra is not a known argument/);
  assert.equal(fake.state.requests.length, 0);
});

test("API errors surface as isError tool results with code and message", async () => {
  const res = await call("get_project", { project_id: 999 });
  assert.equal(res.isError, true);
  assert.match(res.text, /not_found, HTTP 404\): Project not found/);
});

test("get_analysis returns the analysis", async () => {
  const { data } = await call("get_analysis", { project_id: 1 });
  assert.equal(data.analysis.framework, "rails");
});

test("deploy without wait returns the queued deployment", async () => {
  const { data } = await call("deploy", { project_id: 1, branch: "feature/x" });
  assert.equal(data.deployment.status, "queued");
  assert.equal(data.deployment.branch, "feature/x");
  const post = fake.state.requests.find((r) => r.method === "POST");
  assert.deepEqual(post.body, { branch: "feature/x" });
});

test("deploy with wait polls to a terminal status and returns the log tail", async () => {
  const { data } = await call("deploy", { project_id: 1, wait: true, timeout_seconds: 60 });
  assert.equal(data.deployment.status, "running");
  assert.equal(data.timed_out, false);
  assert.ok(data.log_tail.some((l) => l.includes("traffic shifted")));
  // logs were fetched incrementally with after_id
  const logReqs = fake.state.requests.filter((r) => r.path.endsWith("/logs"));
  assert.ok(logReqs.some((r) => r.query.after_id));
});

test("deploy with wait reports failure details and AI explanation", async () => {
  const { data } = await call("deploy", { project_id: 2, wait: true });
  assert.equal(data.deployment.status, "failed");
  assert.equal(data.error.category, "health_check_failed");
  assert.match(data.error.ai_explanation, /PORT/);
});

test("deploy with wait times out cleanly", async () => {
  let t = 0;
  const api = new AnchorApi({ baseUrl: fake.url, token: TOKEN });
  server = new McpServer({ api, sleep: async () => {}, now: () => (t += 20_000) }, (m) => sent.push(m));
  const { data } = await call("deploy", { project_id: 1, wait: true, timeout_seconds: 10 });
  assert.equal(data.timed_out, true);
  assert.match(data.note, /Still in progress/);
});

test("concurrent deploy conflict is reported", async () => {
  await call("deploy", { project_id: 1 });
  const res = await call("deploy", { project_id: 1 });
  assert.equal(res.isError, true);
  assert.match(res.text, /deployment_in_progress/);
});

test("get_deployment, get_logs with after_id, cancel_deployment", async () => {
  const { data: created } = await call("deploy", { project_id: 1 });
  const depId = created.deployment.id;

  const { data: d } = await call("get_deployment", { deployment_id: depId });
  assert.equal(d.deployment.status, "building");

  const { data: logs } = await call("get_logs", { deployment_id: depId });
  assert.equal(logs.logs.length, 1);
  const { data: none } = await call("get_logs", { deployment_id: depId, after_id: logs.next_after_id });
  assert.equal(none.logs.length, 0);

  const { data: cancelled } = await call("cancel_deployment", { deployment_id: depId });
  assert.equal(cancelled.deployment.status, "cancelled");
  const again = await call("cancel_deployment", { deployment_id: depId });
  assert.equal(again.isError, true);
});

test("rollback passes the optional target deployment", async () => {
  const { data } = await call("rollback", { project_id: 1, deployment_id: 42 });
  assert.equal(data.deployment.triggered_by, "rollback");
  assert.deepEqual(fake.state.requests.at(-1).body, { deployment_id: 42 });
  await call("rollback", { project_id: 1 });
  assert.deepEqual(fake.state.requests.at(-1).body, {});
});

test("list_secrets returns names only; set_secret never echoes the value", async () => {
  const { data: list } = await call("list_secrets", { project_id: 1 });
  assert.deepEqual(list.secrets, [{ key: "DATABASE_URL" }]);

  const res = await call("set_secret", { project_id: 1, key: "STRIPE_KEY", value: "sk_live_should_not_echo" });
  assert.equal(res.isError, false);
  assert.ok(!res.text.includes("sk_live_should_not_echo"));
  assert.equal(fake.state.secrets[1].STRIPE_KEY, "sk_live_should_not_echo");
  assert.equal(fake.state.requests.at(-1).method, "PUT");
});

test("set_secret rejects bad keys before calling the API", async () => {
  const res = await call("set_secret", { project_id: 1, key: "lower-case", value: "v" });
  assert.equal(res.isError, true);
  assert.equal(fake.state.requests.length, 0);
});

test("path segments are URL-encoded", async () => {
  const api = new AnchorApi({ baseUrl: fake.url, token: TOKEN });
  await assert.rejects(api.getProject("../me"), /No route/);
  assert.equal(fake.state.requests.at(-1).path, "/api/v1/projects/..%2Fme");
});

test("a bad token is reported as unauthorized", async () => {
  const api = new AnchorApi({ baseUrl: fake.url, token: "anc_wrong" });
  server = new McpServer({ api }, (m) => sent.push(m));
  const res = await call("list_projects", {});
  assert.equal(res.isError, true);
  assert.match(res.text, /unauthorized/);
  assert.ok(!res.text.includes("anc_wrong"));
});

test("network failures are reported without crashing", async () => {
  const api = new AnchorApi({ baseUrl: "http://127.0.0.1:1", token: TOKEN });
  server = new McpServer({ api }, (m) => sent.push(m));
  const res = await call("list_projects", {});
  assert.equal(res.isError, true);
  assert.match(res.text, /network_error/);
});
