# JSON API (`/api/v1`)

The [CLI](cli.md) and the [MCP server](mcp.md) are built on this API, and you can call it directly
from scripts and CI. The controllers are in [`app/controllers/api/v1/`](../app/controllers/api/v1),
and the JSON shapes are defined in one place, [`serialization.rb`](../app/controllers/api/v1/serialization.rb).

## Authentication

```http
Authorization: Bearer anc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

- Create tokens in the web app under **Settings → API tokens**. A token is shown once, and Anchor
  stores only its SHA-256 digest. Revoking a token takes effect immediately.
- A token acts as its owner and has full access. **There are no scopes yet.**
- Every lookup is scoped to the token's user, so another user's project returns `404`, the same as
  one that doesn't exist.
- A missing or invalid token returns `401` with `WWW-Authenticate: Bearer realm="anchor"`.

```console
$ curl -i http://localhost:3000/api/v1/me
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer realm="anchor"
{"error":{"code":"unauthorized","message":"Missing API token. Send `Authorization: Bearer <token>`."}}
```

## Errors

Every error uses the same envelope. Some codes add extra fields.

```json
{ "error": { "code": "missing_secrets", "message": "Missing required secrets: DATABASE_URL. Add them before deploying.", "missing_secrets": ["DATABASE_URL"] } }
```

| HTTP | `code` | When |
|---|---|---|
| 400 | `bad_request` | A required parameter is missing, or the body isn't valid JSON |
| 401 | `unauthorized` | The token is missing, invalid, or revoked |
| 404 | `not_found` | The resource doesn't exist or isn't yours |
| 409 | `deploy_in_progress` | The project already has an active deployment (deploy or rollback) |
| 409 | `not_cancellable` | The deployment already finished |
| 409 | `invalid_transition` | The state machine refused the status change |
| 422 | `missing_secrets` | Required env vars aren't set. Adds `missing_secrets: [...]`. |
| 422 | `invalid_branch` | The branch name failed validation (no leading `-`, no `..`, and only `[A-Za-z0-9._/-]`, up to 255 characters) |
| 422 | `rollback_failed` | There is no eligible target, or the target never went live |
| 422 | `validation_failed` | A secret key or value is invalid |
| 429 | `quota_exceeded` | The daily deploy quota (20) is used up |
| 429 | `rate_limited` | Rack::Attack throttle. Sends a `Retry-After` header. |

## Rate limits

| Throttle | Limit |
|---|---|
| Per token (all `/api/v1`) | 600 requests / 5 min |
| Per IP (all `/api/v1`) | 1200 requests / 5 min |
| Deploys and rollbacks per token | 30 / hour |
| Deploy quota per user (every entry point) | 20 / day, 200 / month |

## Identifiers and pagination

- `:id` for a project can be the numeric id **or** the slug, e.g. `/api/v1/projects/hello-anchor`.
- `?limit=` is clamped to between 1 and 100. The defaults are 50 for projects, 20 for deployments,
  and 500 for logs (maximum 1000).

## Objects

**Deployment**

```json
{
  "id": 6, "project_id": 1, "status": "running", "triggered_by": "rollback",
  "branch": "master", "commit_sha": "bbed28cb775515c10d98d8e807aae4ac06e0fa8c",
  "commit_message": "Rollback to #4 (feat(ci): add publish workflow (#22))",
  "service_url": "http://localhost:51444", "revision_name": "anchor-cl-hello-anchor-4",
  "error_message": null, "error_category": null,
  "ai_explanation": null, "ai_details": null,
  "started_at": "2026-09-27T15:18:33.537Z", "finished_at": "2026-09-27T15:18:34.249Z",
  "created_at": "2026-09-27T15:18:33.502Z"
}
```

- `status`: `queued`, `analyzing`, `building`, `deploying`, `health_check`, `running`, `failed`,
  `cancelled`, or `rolled_back`. `pending`, `cloning`, `detecting`, and `success` can appear on rows
  created by older releases. The final statuses are `running`, `success`, `failed`, `cancelled`, and
  `rolled_back`.
- `triggered_by`: `manual` (web UI), `webhook`, `cli` (API, CLI, and MCP), `rollback`, or `api`.

**Project**

`id`, `name`, `slug`, `status`, `framework`, `repository` (`owner/repo`), `production_branch`, `url`
(the live URL), `provider` (`gcp_cloud_run` | `local_docker`), `region`, `analysis_status`,
`created_at`, `updated_at`, and `latest_deployment` (a Deployment or `null`).

**Log line**: `id`, `message` (redacted server-side), `level` (`debug|info|warn|error`), `source`, `logged_at`.

**Secret**: `key`, `created_at`, `updated_at`. **Values are never returned.**

## Endpoints

### `GET /api/v1/me`

```json
{"user":{"id":1,"github_login":"demo","name":"Demo User","email":"demo@anchor.local",
 "quota":{"deployments_today":2,"deployments_this_month":2,"daily_limit":20,"monthly_limit":200}},
 "token":{"id":3,"name":"docs"}}
```

### `GET /api/v1/projects?limit=`

Returns `200 {"projects": [Project, ...]}`. Each project includes its newest deployment.

### `GET /api/v1/projects/:id`

Returns `200 {"project": Project}`.

### `GET /api/v1/projects/:id/analysis`

```json
{ "analysis": {
    "status": "complete", "analyzed_at": "…", "framework": "docker",
    "preflight": [ { "id": "bind_localhost", "severity": "error", "message": "…",
                     "file": "server.js", "line": 12, "fix": "Listen on \"0.0.0.0\" …" } ],
    "result": { "framework": "docker", "port": 8000, "detected_env_vars": [ … ], … } } }
```

`preflight` is copied to the top level for convenience. See [preflight.md](preflight.md).

### `GET /api/v1/projects/:id/deployments?limit=`

Returns `200 {"deployments": [Deployment, ...]}`, newest first.

### `POST /api/v1/projects/:id/deployments`

Body (optional): `{"branch": "feature/x"}`. The default is the production branch.

Returns `202 {"deployment": Deployment}` with `status: "queued"` and `triggered_by: "cli"`. It runs
the same guards as the web UI through `Deployments::Starter`: branch format, one active deployment
per project, required secrets, and the quota. Failures return `409 deploy_in_progress`,
`422 missing_secrets`, `422 invalid_branch`, or `429 quota_exceeded`.

```bash
curl -s -XPOST -H "Authorization: Bearer $ANCHOR_TOKEN" \
  -H 'Content-Type: application/json' -d '{"branch":"main"}' \
  http://localhost:3000/api/v1/projects/hello-anchor/deployments
```

### `POST /api/v1/projects/:id/rollback`

Body (optional): `{"deployment_id": 4}`. Without it, Anchor rolls back to the newest earlier healthy
deployment whose revision differs from the live one.

Returns `202 {"deployment": Deployment}` for a new deployment with `triggered_by: "rollback"`. Failures
return `409 deploy_in_progress` or `422 rollback_failed` (for example, `No previous healthy deployment
with a revision to roll back to.`).

### `GET /api/v1/deployments/:id`

Returns `200 {"deployment": Deployment}`.

### `GET /api/v1/deployments/:id/logs?after_id=&limit=`

```json
{ "logs": [ { "id": 222, "message": "Rollback requested by demo: shifting traffic to revision anchor-cl-hello-anchor-4.",
              "level": "info", "source": "system", "logged_at": "2026-09-27T15:18:33.509Z" } ],
  "next_after_id": 223 }
```

To follow a running deployment, poll with `after_id=<next_after_id>`. When there are no new lines,
`next_after_id` stays the same.

### `POST /api/v1/deployments/:id/cancel`

Returns `200 {"deployment": Deployment}` with `status: "cancelled"`. It also stops the provider build
on a best-effort basis. If the deployment already finished, it returns `409 not_cancellable`:

```json
{"error":{"code":"not_cancellable","message":"Deployment is already running and cannot be cancelled."}}
```

### `GET /api/v1/projects/:id/secrets`

Returns `200 {"secrets": [{"key": "DATABASE_URL", "created_at": "…", "updated_at": "…"}]}`.

### `PUT /api/v1/projects/:id/secrets/:key`

Body: `{"value": "…"}`. Returns `201` when the secret is created or `200` when it is updated, with
`{"secret": Secret}`. Keys must match `^[A-Z][A-Z0-9_]*$`. `PORT`, `HOST`, `RAILS_ENV`, `RACK_ENV`,
and `NODE_ENV` are reserved. Values can be up to 32 KiB. The new value takes effect on the next deploy.

### `DELETE /api/v1/projects/:id/secrets/:key`

Returns `204`, or `404` if the key doesn't exist.

## Other HTTP endpoints (no token)

| Path | Purpose |
|---|---|
| `GET /healthz` | Liveness: `{"status":"ok","time":…}` |
| `GET /readyz` | Readiness: database, Redis, Sidekiq processes, and queue latency, e.g. `{"status":"ok","checks":{"database":{"ok":true},"redis":{…},"sidekiq":{"ok":true,"processes":1},"queues":{"max_latency":0,"threshold":300}}}` |
| `GET /up` | The Rails default health check |
| `POST /webhooks/github?project=<slug>` | GitHub push webhook, verified with the project's HMAC secret. The exact URL is on the project's edit page. |
