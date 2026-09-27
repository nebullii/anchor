#!/usr/bin/env node
// Entry point: `ANCHOR_URL=... ANCHOR_TOKEN=anc_... anchor-mcp`
import { AnchorApi } from "../src/api.js";
import { serveStdio } from "../src/server.js";

const baseUrl = process.env.ANCHOR_URL;
const token = process.env.ANCHOR_TOKEN;

if (!baseUrl || !token) {
  process.stderr.write(
    "[anchor-mcp] ANCHOR_URL and ANCHOR_TOKEN must be set.\n" +
      "  Create a token in Anchor (Settings -> API tokens), then e.g.:\n" +
      "  claude mcp add anchor --env ANCHOR_URL=https://anchor.example.com --env ANCHOR_TOKEN=anc_... -- npx anchor-mcp\n",
  );
  process.exit(1);
}

try {
  const url = new URL(baseUrl);
  const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !local) {
    process.stderr.write(`[anchor-mcp] warning: ${url.origin} is not HTTPS; your token will be sent in cleartext.\n`);
  }
} catch {
  process.stderr.write(`[anchor-mcp] ANCHOR_URL is not a valid URL: ${baseUrl}\n`);
  process.exit(1);
}

const api = new AnchorApi({ baseUrl, token });
const pollIntervalMs = Number(process.env.ANCHOR_MCP_POLL_MS) || 3000;

await serveStdio({ api, pollIntervalMs });
