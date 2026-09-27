import { test } from "node:test";
import assert from "node:assert/strict";
import { tools } from "../src/tools.js";
import { validateArgs } from "../src/validate.js";

const schemaOf = (name) => tools.find((t) => t.name === name).inputSchema;

test("project_id accepts a numeric id, a numeric string, or a slug", () => {
  const schema = schemaOf("get_project");
  assert.equal(validateArgs(schema, { project_id: 3 }).args.project_id, 3);
  assert.equal(validateArgs(schema, { project_id: "3" }).args.project_id, 3);
  assert.equal(validateArgs(schema, { project_id: "hello-anchor" }).args.project_id, "hello-anchor");
});

test("project_id rejects junk", () => {
  const schema = schemaOf("get_project");
  assert.ok(validateArgs(schema, { project_id: "../etc" }).errors.length > 0);
  assert.ok(validateArgs(schema, { project_id: true }).errors.length > 0);
});

test("secret values are capped at the server's 32 KiB limit", () => {
  const schema = schemaOf("set_secret");
  const big = "x".repeat(32 * 1024 + 1);
  assert.ok(validateArgs(schema, { project_id: 1, key: "A", value: big }).errors.length > 0);
});
