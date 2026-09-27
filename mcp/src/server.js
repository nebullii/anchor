// Dependency-free MCP server over stdio (newline-delimited JSON-RPC 2.0).
//
// Implements the subset of the Model Context Protocol a tools-only server
// needs: initialize, notifications/initialized, ping, tools/list and
// tools/call. Written without @modelcontextprotocol/sdk so it runs with a
// stock Node >= 18 and no npm install.
//
// stdout carries protocol messages only; diagnostics go to stderr.

import { createInterface } from "node:readline";
import { ApiError } from "./api.js";
import { tools, toolsByName } from "./tools.js";
import { validateArgs } from "./validate.js";

export const SERVER_INFO = { name: "anchor", title: "Anchor", version: "0.1.0" };
export const SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS =
  "Anchor deploys GitHub repositories to the user's own cloud (or local Docker). Typical flow: " +
  "list_projects -> get_analysis (check preflight errors and required env vars) -> list_secrets / " +
  "set_secret for anything missing -> deploy with wait=true. If a deploy fails, read error.ai_explanation " +
  "and get_logs, fix the code, push, and deploy again. If a live deploy is broken, use rollback.";

const ERR = { parse: -32700, invalidRequest: -32600, methodNotFound: -32601, invalidParams: -32602, internal: -32603 };

export class McpServer {
  /**
   * @param {object} ctx  { api, pollIntervalMs?, sleep? } passed to tool handlers
   * @param {(msg: object) => void} send  writes one JSON-RPC message
   * @param {(line: string) => void} [log]  diagnostics (stderr)
   */
  constructor(ctx, send, log = () => {}) {
    this.ctx = ctx;
    this.send = send;
    this.log = log;
    this.initialized = false;
  }

  async handleLine(line) {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return this.send(error(null, ERR.parse, "Parse error"));
    }
    if (Array.isArray(msg)) {
      // JSON-RPC batches were removed from MCP in 2025-06-18; answer each anyway.
      for (const m of msg) await this.handleMessage(m);
      return;
    }
    await this.handleMessage(msg);
  }

  async handleMessage(msg) {
    if (!msg || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
      if (msg && msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) return; // a response to us
      return this.send(error(msg?.id ?? null, ERR.invalidRequest, "Invalid Request"));
    }

    const isNotification = msg.id === undefined;
    try {
      const result = await this.dispatch(msg.method, msg.params || {});
      if (!isNotification && result !== undefined) this.send({ jsonrpc: "2.0", id: msg.id, result });
    } catch (err) {
      if (isNotification) return;
      if (err instanceof RpcError) return this.send(error(msg.id, err.code, err.message));
      this.log(`internal error in ${msg.method}: ${err?.stack || err}`);
      this.send(error(msg.id, ERR.internal, "Internal error"));
    }
  }

  async dispatch(method, params) {
    switch (method) {
      case "initialize": {
        this.initialized = true;
        const requested = params.protocolVersion;
        const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.includes(requested)
          ? requested
          : SUPPORTED_PROTOCOL_VERSIONS[0];
        return {
          protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS,
        };
      }
      case "notifications/initialized":
      case "notifications/cancelled":
        return undefined;
      case "ping":
        return {};
      case "tools/list":
        return {
          tools: tools.map(({ name, title, description, inputSchema, annotations }) => ({
            name, title, description, inputSchema, annotations,
          })),
        };
      case "tools/call":
        return this.callTool(params);
      default:
        if (method.startsWith("notifications/")) return undefined;
        throw new RpcError(ERR.methodNotFound, `Method not found: ${method}`);
    }
  }

  async callTool({ name, arguments: rawArgs }) {
    const tool = toolsByName.get(name);
    if (!tool) throw new RpcError(ERR.invalidParams, `Unknown tool: ${name}`);

    const { args, errors } = validateArgs(tool.inputSchema, rawArgs);
    if (errors.length) return toolError(`Invalid arguments for ${name}: ${errors.join("; ")}`);

    try {
      const result = await tool.handler(this.ctx, args);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }], isError: false };
    } catch (err) {
      if (err instanceof ApiError) {
        return toolError(`Anchor API error (${err.code}${err.status ? `, HTTP ${err.status}` : ""}): ${err.message}`);
      }
      this.log(`tool ${name} failed: ${err?.stack || err}`);
      return toolError(`${name} failed: ${err?.message || "unexpected error"}`);
    }
  }
}

class RpcError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const error = (id, code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });
const toolError = (text) => ({ content: [{ type: "text", text }], isError: true });

// Wires the server to process stdin/stdout.
export function serveStdio(ctx, { input = process.stdin, output = process.stdout, log } = {}) {
  const logger = log || ((line) => process.stderr.write(`[anchor-mcp] ${line}\n`));
  const server = new McpServer(ctx, (msg) => output.write(JSON.stringify(msg) + "\n"), logger);
  const rl = createInterface({ input, crlfDelay: Infinity });

  // Process messages in order; tool calls may be slow (deploy with wait).
  let chain = Promise.resolve();
  rl.on("line", (line) => {
    chain = chain.then(() => server.handleLine(line)).catch((err) => logger(String(err)));
  });
  return new Promise((resolve) => rl.on("close", () => chain.then(resolve)));
}
