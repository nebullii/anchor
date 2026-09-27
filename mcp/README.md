# Anchor MCP server

Lets coding agents (Claude Code, Cursor, Claude Desktop, any MCP client) deploy and operate apps on
Anchor. An agent can check what a repo needs, set missing secrets, deploy, wait for the result, read
the logs and AI error explanation, fix the code, and roll back if a deploy goes wrong.

- **No dependencies.** It's plain Node ≥ 18 with no `npm install` step. It speaks MCP over stdio
  (newline-delimited JSON-RPC 2.0, protocol versions `2025-06-18`, `2025-03-26` and `2024-11-05`).
- **Uses only the JSON API.** Every tool calls Anchor's `/api/v1` with your API token. It never touches
  Anchor's database or your cloud directly, so it can't do anything the token can't.

## Setup

1. In Anchor, create an API token under **Settings → API tokens**. Tokens start with `anc_` and are
   shown only once.
2. Register the server with your client (examples below). Use the absolute path to
   `mcp/bin/anchor-mcp.js` in your Anchor checkout.

| Variable             | Required | Description                                                  |
| -------------------- | -------- | ------------------------------------------------------------ |
| `ANCHOR_URL`         | yes      | Base URL of your Anchor instance, e.g. `https://anchor.example.com` |
| `ANCHOR_TOKEN`       | yes      | API token (`anc_...`)                                        |
| `ANCHOR_MCP_POLL_MS` | no       | Poll interval for `deploy` with `wait: true` (default 3000)   |

### Claude Code

```bash
claude mcp add anchor \
  --env ANCHOR_URL=https://anchor.example.com \
  --env ANCHOR_TOKEN=anc_xxxxxxxxxxxxxxxx \
  -- node /absolute/path/to/anchor/mcp/bin/anchor-mcp.js
```

Add `--scope user` to make it available in every project, or `--scope project` to write a shared
`.mcp.json`. If you share it, don't commit the token: set `ANCHOR_TOKEN` in your shell environment
instead. Check the connection with `claude mcp list`, or with `/mcp` inside a session.

### Cursor

Add this to `.cursor/mcp.json` in your project, or to `~/.cursor/mcp.json` for all projects:

```json
{
  "mcpServers": {
    "anchor": {
      "command": "node",
      "args": ["/absolute/path/to/anchor/mcp/bin/anchor-mcp.js"],
      "env": {
        "ANCHOR_URL": "https://anchor.example.com",
        "ANCHOR_TOKEN": "anc_xxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

### Claude Desktop

Claude Desktop uses the same `mcpServers` block as Cursor, in `claude_desktop_config.json`.

## Tools

| Tool                | What it does                                                          | Side effects |
| ------------------- | --------------------------------------------------------------------- | ------------ |
| `list_projects`     | Lists projects with their latest deployment status                    | read-only |
| `get_project`       | Shows project config: provider, branch, memory, health check, URL     | read-only |
| `get_analysis`      | Shows detected framework and port, required env vars, and preflight findings (errors block deploys) | read-only |
| `list_deployments`  | Lists recent deployments for a project                                 | read-only |
| `deploy`            | Starts a deploy. With `wait: true`, polls until it finishes and returns the log tail plus the AI explanation if it failed | creates a deployment |
| `get_deployment`    | Shows status, revision, URL, error, error category and AI explanation | read-only |
| `get_logs`          | Returns log lines. Pass `after_id` (the last response's `next_after_id`) to get only new lines | read-only |
| `cancel_deployment` | Cancels an in-progress deployment and stops its build                  | destructive |
| `rollback`          | Moves traffic back to the previous (or a given) successful deployment | destructive |
| `list_secrets`      | Lists secret **names** only; values are never returned                | read-only |
| `set_secret`        | Creates or updates a secret. The value is never echoed back           | writes a secret |

Each tool declares MCP `annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`), so clients
can auto-approve reads and ask before a rollback or cancel.

### Typical agent loop

```
list_projects → get_analysis(project_id)
  → list_secrets / set_secret for missing required env vars
  → deploy(project_id, wait: true)
      ├─ running → done (deployment.service_url)
      └─ failed  → read error.ai_explanation + log_tail, fix the code, push, deploy again
live but broken → rollback(project_id)
```

## Behaviour and safety

- API errors come back as tool results with `isError: true` and the API's error code and message,
  so the agent can see what went wrong and react. JSON-RPC errors are reserved for protocol problems
  such as an unknown tool or bad JSON.
- Arguments are checked against each tool's `inputSchema` before any request is sent. Unknown
  arguments are rejected, and numeric strings are accepted as ids.
- Path parameters are URL-encoded, so an id can't change which endpoint gets called.
- The token is sent only in the `Authorization` header and is never logged. The server warns on
  stderr if `ANCHOR_URL` isn't HTTPS and isn't localhost.
- Requests are handled one at a time. While `deploy` with `wait: true` is running (up to
  `timeout_seconds`, default 900), other calls queue behind it.

## Development

```bash
cd mcp
npm test                     # node --test: unit tests plus an end-to-end stdio test against a fake API
ANCHOR_URL=http://localhost:3000 ANCHOR_TOKEN=anc_... node bin/anchor-mcp.js   # run by hand
```

`test/fake_api.js` is an in-memory implementation of the `/api/v1` contract, and all the tests run
against it. They make no network calls beyond 127.0.0.1.
