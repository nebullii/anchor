// Tool definitions exposed over MCP. Each tool has:
//   name, title, description  — written for an LLM agent choosing a tool
//   inputSchema               — JSON Schema for arguments
//   annotations               — MCP behaviour hints (read-only / destructive)
//   handler(ctx, args)        — returns a JSON-serialisable result
//
// Handlers only call AnchorApi; they never touch Anchor's database.

import { ApiError } from "./api.js";

export const TERMINAL_STATUSES = new Set(["running", "success", "failed", "cancelled", "rolled_back"]);
const SECRET_KEY = /^[A-Z][A-Z0-9_]*$/;
const WAIT_LOG_TAIL = 40;

// Plain integer (no anyOf) for compatibility with clients that only accept
// simple schemas; numeric strings are coerced by the validator.
const id = (description) => ({ type: "integer", minimum: 1, description });
// Projects can be addressed by numeric id or slug (the API accepts both).
const projectRef = (description) => ({
  type: ["integer", "string"], minimum: 1, pattern: "^[A-Za-z0-9][A-Za-z0-9_-]*$",
  description: `${description} (numeric id or slug)`,
});

// Unwraps {"deployment": {...}} style envelopes while tolerating bare objects.
const unwrap = (data, key) => (data && typeof data === "object" && key in data ? data[key] : data);

export const tools = [
  {
    name: "list_projects",
    title: "List projects",
    description:
      "List every Anchor project the token can access, with id, name, framework, provider and the " +
      "latest deployment status. Call this first to find the project_id for other tools.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }) => api.listProjects(),
  },
  {
    name: "get_project",
    title: "Get project",
    description:
      "Get one project's configuration: repository, production branch, provider (gcp_cloud_run or " +
      "local_docker), region, memory, health check path, service URL and latest deployment.",
    inputSchema: {
      type: "object",
      properties: { project_id: projectRef("Project id from list_projects") },
      required: ["project_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }, { project_id }) => api.getProject(project_id),
  },
  {
    name: "get_analysis",
    title: "Get repository analysis",
    description:
      "Get the repository analysis for a project: detected framework, runtime, port, database, " +
      "required environment variables, AI suggestions, and preflight findings. Preflight findings " +
      "with severity \"error\" block deploys — fix them (and set missing secrets) before calling deploy.",
    inputSchema: {
      type: "object",
      properties: { project_id: projectRef("Project id") },
      required: ["project_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }, { project_id }) => api.getAnalysis(project_id),
  },
  {
    name: "list_deployments",
    title: "List deployments",
    description: "List a project's most recent deployments (newest first) with status, branch, commit and timing.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: projectRef("Project id"),
        limit: { type: "integer", minimum: 1, maximum: 100, default: 10, description: "How many to return" },
      },
      required: ["project_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }, { project_id, limit = 10 }) => api.listDeployments(project_id, limit),
  },
  {
    name: "deploy",
    title: "Deploy project",
    description:
      "Start a new deployment of a project (build the image, deploy a new revision, health check, then " +
      "shift traffic). Returns immediately with the queued deployment unless wait=true, in which case it " +
      "polls until the deployment reaches a terminal status (running, failed, cancelled, rolled_back) or " +
      "timeout_seconds elapses, and returns the final deployment plus the last log lines and, on failure, " +
      "the AI error explanation. Only one deployment per project runs at a time.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: projectRef("Project id"),
        branch: { type: "string", maxLength: 255, description: "Git branch to deploy; defaults to the production branch" },
        wait: { type: "boolean", default: false, description: "Block until the deployment finishes" },
        timeout_seconds: {
          type: "integer", minimum: 10, maximum: 1800, default: 900,
          description: "Max time to wait when wait=true",
        },
      },
      required: ["project_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    handler: async (ctx, { project_id, branch, wait = false, timeout_seconds = 900 }) => {
      const created = unwrap(await ctx.api.createDeployment(project_id, branch), "deployment");
      if (!wait) return { deployment: created, note: "Deployment queued. Use get_deployment / get_logs to follow it." };
      return waitForDeployment(ctx, created, timeout_seconds);
    },
  },
  {
    name: "get_deployment",
    title: "Get deployment",
    description:
      "Get a deployment's status, commit, revision, service URL, timing, error message, error category " +
      "and AI explanation (for failed deployments).",
    inputSchema: {
      type: "object",
      properties: { deployment_id: id("Deployment id") },
      required: ["deployment_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }, { deployment_id }) => api.getDeployment(deployment_id),
  },
  {
    name: "get_logs",
    title: "Get deployment logs",
    description:
      "Get build and deploy log lines for a deployment, oldest first. Pass after_id (the previous " +
      "response's next_after_id) to fetch only new lines, so you can follow a running deployment " +
      "incrementally without re-reading the whole log.",
    inputSchema: {
      type: "object",
      properties: {
        deployment_id: id("Deployment id"),
        after_id: { type: "integer", minimum: 0, description: "Only return log lines with id greater than this" },
      },
      required: ["deployment_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }, { deployment_id, after_id }) => api.getLogs(deployment_id, after_id),
  },
  {
    name: "cancel_deployment",
    title: "Cancel deployment",
    description:
      "Cancel an in-progress deployment. Stops the build if it is still running. Has no effect on " +
      "deployments that already finished. The currently live revision keeps serving traffic.",
    inputSchema: {
      type: "object",
      properties: { deployment_id: id("Deployment id") },
      required: ["deployment_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true },
    handler: ({ api }, { deployment_id }) => api.cancelDeployment(deployment_id),
  },
  {
    name: "rollback",
    title: "Roll back project",
    description:
      "Shift production traffic back to an earlier successful revision. Without deployment_id it rolls " +
      "back to the previous successful deployment. Creates a new deployment with triggered_by=rollback; " +
      "follow it with get_deployment. Use this when a deploy is live but broken.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: projectRef("Project id"),
        deployment_id: id("Optional: the earlier successful deployment to roll back to"),
      },
      required: ["project_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    handler: ({ api }, { project_id, deployment_id }) => api.rollback(project_id, deployment_id),
  },
  {
    name: "list_secrets",
    title: "List secret names",
    description:
      "List the names of a project's secrets (environment variables). Values are never returned. " +
      "Compare with get_analysis's required env vars to find what is missing.",
    inputSchema: {
      type: "object",
      properties: { project_id: projectRef("Project id") },
      required: ["project_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
    handler: ({ api }, { project_id }) => api.listSecrets(project_id),
  },
  {
    name: "set_secret",
    title: "Set secret",
    description:
      "Create or update a project secret (an environment variable injected at deploy time). Keys are " +
      "SCREAMING_SNAKE_CASE (e.g. DATABASE_URL); PORT, HOST, RAILS_ENV, RACK_ENV and NODE_ENV are reserved. " +
      "Takes effect on the next deploy. Only set values the user gave you — never invent credentials.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: projectRef("Project id"),
        key: { type: "string", pattern: SECRET_KEY.source, maxLength: 255, description: "Secret name, e.g. DATABASE_URL" },
        value: { type: "string", minLength: 1, maxLength: 32768, description: "Secret value (max 32 KiB)" },
      },
      required: ["project_id", "key", "value"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    handler: async ({ api }, { project_id, key, value }) => {
      await api.setSecret(project_id, key, value);
      // Never echo the value back into the agent transcript.
      return { ok: true, project_id, key, note: "Secret saved. Redeploy for it to take effect." };
    },
  },
];

export const toolsByName = new Map(tools.map((t) => [t.name, t]));

// Polls a deployment until it reaches a terminal status or the timeout.
export async function waitForDeployment(ctx, deployment, timeoutSeconds) {
  const { api, pollIntervalMs = 3000, sleep = defaultSleep, now = Date.now } = ctx;
  const deadline = now() + timeoutSeconds * 1000;
  const logs = [];
  let afterId;
  let current = deployment;

  const pullLogs = async () => {
    try {
      const page = await api.getLogs(current.id, afterId);
      for (const line of page.logs || []) logs.push(line);
      if (page.next_after_id !== undefined && page.next_after_id !== null) afterId = page.next_after_id;
      if (logs.length > WAIT_LOG_TAIL * 5) logs.splice(0, logs.length - WAIT_LOG_TAIL);
    } catch (err) {
      if (!(err instanceof ApiError)) throw err; // logs are best-effort while waiting
    }
  };

  while (true) {
    await pullLogs();

    current = unwrap(await api.getDeployment(current.id), "deployment");
    if (TERMINAL_STATUSES.has(current.status)) {
      await pullLogs(); // lines written during the final transition
      return summarise(current, logs, false);
    }
    if (now() >= deadline) return summarise(current, logs, true);
    await sleep(pollIntervalMs);
  }
}

function summarise(deployment, logs, timedOut) {
  const tail = logs.slice(-WAIT_LOG_TAIL).map((l) => `[${l.level || "info"}] ${l.message}`);
  const out = { deployment, timed_out: timedOut, log_tail: tail };
  if (timedOut) out.note = "Still in progress. Call get_deployment or deploy again with wait to keep following it.";
  if (deployment.status === "failed") {
    out.error = {
      message: deployment.error_message,
      category: deployment.error_category,
      ai_explanation: deployment.ai_explanation,
    };
  }
  return out;
}

const defaultSleep = (ms) => new Promise((r) => setTimeout(r, ms));
