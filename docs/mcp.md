# MCP server: Anchor for coding agents

The MCP server in [`mcp/`](../mcp) lets a coding agent operate Anchor. The agent can check what a repo
needs, set secrets, deploy, wait for the result, read logs and the failure explanation, and roll
back. It works with Claude Code, Cursor, Claude Desktop, or any other MCP client.

- The server is plain Node 18.17+ with **no dependencies** and no `npm install` step. It speaks MCP
  over stdio (JSON-RPC 2.0) and supports protocol versions `2025-06-18`, `2025-03-26`, and `2024-11-05`.
- It uses **only** the [JSON API](api.md) with your API token. It never touches Anchor's database or
  your cloud, so it can do nothing the token can't.

[`mcp/README.md`](../mcp/README.md) is the short reference. This page adds client setup and a real
session.

## 1. Create a token

In Anchor, go to **Settings → API tokens → Create**. The token starts with `anc_` and is shown once.

API tokens have no scopes yet, so the agent gets full access to your account. Deploy quotas (20 per
day per user) and the API rate limits (30 deploys or rollbacks per hour per token, 600 requests per
5 minutes per token) still apply.

## 2. Register the server

| Variable | Required | Description |
|---|---|---|
| `ANCHOR_URL` | yes | Base URL, e.g. `http://localhost:3000` or `https://anchor.example.com` |
| `ANCHOR_TOKEN` | yes | `anc_...` |
| `ANCHOR_MCP_POLL_MS` | no | Poll interval for `deploy` with `wait: true` (default 3000) |

### Claude Code

```bash
claude mcp add anchor \
  --env ANCHOR_URL=http://localhost:3000 \
  --env ANCHOR_TOKEN=anc_xxxxxxxxxxxxxxxx \
  -- node /absolute/path/to/anchor/mcp/bin/anchor-mcp.js
```

Add `--scope user` to make the server available in every project. `--scope project` writes a shared
`.mcp.json` instead; if you use it, keep the token out of the file and export `ANCHOR_TOKEN` in your
shell. To check the connection, run `claude mcp list`, or type `/mcp` inside a session.

### Cursor

Put this in `.cursor/mcp.json` for one project, or `~/.cursor/mcp.json` for all projects:

```json
{
  "mcpServers": {
    "anchor": {
      "command": "node",
      "args": ["/absolute/path/to/anchor/mcp/bin/anchor-mcp.js"],
      "env": {
        "ANCHOR_URL": "http://localhost:3000",
        "ANCHOR_TOKEN": "anc_xxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

Claude Desktop reads the same `mcpServers` block from `claude_desktop_config.json`.

## Tools

| Tool | Arguments | Side effects |
|---|---|---|
| `list_projects` | none | read-only |
| `get_project` | `project_id` | read-only |
| `get_analysis` | `project_id` | read-only. Returns framework, port, required env vars, and [preflight findings](preflight.md). |
| `list_deployments` | `project_id`, `limit?` (default 10) | read-only |
| `deploy` | `project_id`, `branch?`, `wait?`, `timeout_seconds?` (default 900) | Creates a deployment. With `wait: true` it returns the final deployment, the last 40 log lines, and, on failure, `error.{message, category, ai_explanation}`. |
| `get_deployment` | `deployment_id` | read-only |
| `get_logs` | `deployment_id`, `after_id?` | read-only. Pass back `next_after_id` to get only new lines. |
| `cancel_deployment` | `deployment_id` | destructive |
| `rollback` | `project_id`, `deployment_id?` | destructive |
| `list_secrets` | `project_id` | read-only. Returns names only. |
| `set_secret` | `project_id`, `key`, `value` | Writes a secret. The value is never echoed back. |

Each tool declares MCP `annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`), so
clients can approve reads automatically and ask before a cancel or rollback.

**Project ids or slugs.** `project_id` accepts the numeric id from `list_projects` or the project
slug (e.g. `hello-anchor`), like the HTTP API. Deployment ids are always numeric.

When the API returns an error (for example `deploy_in_progress` or `missing_secrets`), the server
returns a tool result with `isError: true` and the API's code and message, so the agent can react.
JSON-RPC errors are used only for protocol problems.

## Example session

This transcript comes from the MCP server running against a local Anchor with the seeded demo project.
The JSON is trimmed.

```text
→ initialize {protocolVersion: "2025-06-18"}
← serverInfo {name: "anchor", version: "0.1.0"}, capabilities {tools}

→ tools/list
← list_projects, get_project, get_analysis, list_deployments, deploy, get_deployment,
  get_logs, cancel_deployment, rollback, list_secrets, set_secret

→ tools/call deploy {project_id: 1, wait: true, timeout_seconds: 120}
← {
    "deployment": {
      "id": 8, "project_id": 1, "status": "running", "triggered_by": "cli",
      "branch": "master", "commit_sha": "bbed28cb…",
      "service_url": "http://localhost:51569",
      "revision_name": "anchor-cl-hello-anchor-8",
      "error_message": null, "ai_explanation": null,
      "started_at": "2026-09-27T15:18:59.607Z", "finished_at": "2026-09-27T15:19:03.829Z"
    },
    "timed_out": false,
    "log_tail": [
      "[info] #7 naming to docker.io/anchor-local/cl-hello-anchor:8 done",
      "...",
      "[info] Health check 1/8 passed (HTTP 200).",
      "[info] Shifting 100% of traffic to anchor-cl-hello-anchor-8...",
      "[info] Deployment complete."
    ]
  }
```

Deploys through the API and MCP are recorded with `triggered_by: "cli"`.

A typical loop for an agent:

```text
list_projects → get_analysis(project_id)
  → fix any preflight "error" findings in the code, push
  → list_secrets; set_secret for required env vars the user supplied
  → deploy(project_id, wait: true)
      ├─ running → report deployment.service_url
      └─ failed  → read error.message / error.ai_explanation / log_tail, fix, push, deploy again
live but broken → rollback(project_id)
```

The `set_secret` tool description tells the agent to set only values the user provided and never to
invent credentials.

## Behavior and limits

- Arguments are validated against each tool's `inputSchema` before any request is sent. Unknown
  arguments are rejected.
- Path parameters are URL-encoded, so an id can't change which endpoint is called.
- The token is sent only in the `Authorization` header and is never logged. If `ANCHOR_URL` is
  neither HTTPS nor localhost, the server prints a warning on stderr.
- Requests are handled one at a time. While a `deploy` with `wait: true` is running, other calls
  queue behind it.

## Development

```bash
cd mcp
npm test      # node --test: unit tests plus an end-to-end stdio test against test/fake_api.js
ANCHOR_URL=http://localhost:3000 ANCHOR_TOKEN=anc_... node bin/anchor-mcp.js   # run by hand
```
