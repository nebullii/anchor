# Anchor — Database Schema

## Overview

Single PostgreSQL database. Six tables. No multi-database setup in V1. All foreign keys enforced at the database level.

---

## Entity Relationship Diagram

```
users
  │
  ├── has_many ──────────────────────────────── repositories
  │                                                  │
  └── has_many ──── projects ◀── belongs_to ─────────┘
                        │
                        ├── has_many ──── deployments
                        │                     │
                        │                     └── has_many ── deployment_logs
                        │
                        └── has_many ──── secrets
```

---

## Tables

### `users`

Stores GitHub OAuth identity and GCP defaults. GitHub token is encrypted at rest.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigint | PK | |
| `github_id` | string | NOT NULL, UNIQUE | GitHub's numeric user ID |
| `github_login` | string | NOT NULL, UNIQUE | GitHub username |
| `github_token` | string | NOT NULL | Stored encrypted (`attr_encrypted`) |
| `name` | string | | Display name from GitHub profile |
| `email` | string | | From GitHub OAuth scope |
| `avatar_url` | string | | GitHub profile image URL |
| `default_gcp_project_id` | string | | Pre-fills project forms |
| `default_gcp_region` | string | DEFAULT "us-central1" | |
| `created_at` | datetime | NOT NULL | |
| `updated_at` | datetime | NOT NULL | |

**Indexes:** `github_id` (unique), `github_login` (unique), `email`

**Encryption detail:** `attr_encrypted` writes the ciphertext to `github_token` in the DB. The column stores a base64-encoded AES-256-CBC ciphertext. The encryption key comes from `Rails.application.credentials.dig(:encryption, :key)`.

---

### `repositories`

GitHub repositories synced from the user's account. Updated on every sync (manual or post-OAuth).

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigint | PK | |
| `user_id` | bigint | NOT NULL, FK → users | |
| `github_id` | string | NOT NULL, UNIQUE | GitHub's numeric repo ID |
| `name` | string | NOT NULL | Short name e.g. "my-app" |
| `full_name` | string | NOT NULL, UNIQUE | "owner/repo" format |
| `owner_login` | string | NOT NULL | GitHub username of the owner |
| `description` | text | | |
| `default_branch` | string | DEFAULT "main" | |
| `clone_url` | string | NOT NULL | HTTPS clone URL |
| `html_url` | string | NOT NULL | GitHub web URL |
| `private` | boolean | NOT NULL, DEFAULT false | |
| `language` | string | | Primary language (from GitHub) |
| `size_kb` | integer | | Repo size in kilobytes |
| `last_synced_at` | datetime | | Tracks freshness |
| `created_at` | datetime | NOT NULL | |
| `updated_at` | datetime | NOT NULL | |

**Indexes:** `github_id` (unique), `full_name` (unique), `user_id` (via `t.references`), `owner_login`, `last_synced_at`

**Key method:** `authenticated_clone_url` embeds the user's GitHub token into the URL for `git clone`. The URL is never logged.

---

### `projects`

One project = one Cloud Run service. A project ties a repository to a GCP deployment target.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigint | PK | |
| `user_id` | bigint | NOT NULL, FK → users | |
| `repository_id` | bigint | NOT NULL, FK → repositories | |
| `name` | string | NOT NULL | Human-readable project name |
| `slug` | string | NOT NULL, UNIQUE | URL-safe, auto-generated from name |
| `gcp_project_id` | string | NOT NULL | GCP project identifier |
| `gcp_region` | string | NOT NULL, DEFAULT "us-central1" | Cloud Run region |
| `service_name` | string | | Cloud Run service name (auto: "cl-{slug}") |
| `framework` | string | | Detected: rails/node/python/static/docker |
| `runtime` | string | | e.g. ruby3.2, node20, python3.11 |
| `port` | integer | | Container port |
| `production_branch` | string | DEFAULT "main" | Branch to deploy |
| `auto_deploy` | boolean | NOT NULL, DEFAULT false | Reserved for webhook-triggered deploys |
| `status` | string | NOT NULL, DEFAULT "inactive" | inactive/active/building/error |
| `latest_url` | string | | Cloud Run URL of last successful deploy |
| `created_at` | datetime | NOT NULL | |
| `updated_at` | datetime | NOT NULL | |

**Indexes:** `slug` (unique), `[user_id, name]` (unique), `user_id` (via `t.references`), `repository_id` (via `t.references`), `status`, `gcp_project_id`, `service_name`

**Notes:**
- `framework`, `runtime`, `port` are denormalized from `FrameworkDetection` for quick display without a join
- `slug` is auto-generated on create with a counter suffix to guarantee uniqueness (e.g. `my-app`, `my-app-2`)
- `service_name` defaults to `cl-{slug}` on create

---

### `deployments`

One record per deployment attempt. Immutable history — never updated in place after creation except for status transitions and result fields.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigint | PK | |
| `project_id` | bigint | NOT NULL, FK → projects | |
| `status` | string | NOT NULL, DEFAULT "pending" | See status lifecycle below |
| `commit_sha` | string | | Full SHA, populated after clone |
| `commit_message` | string | | First line of commit message |
| `commit_author` | string | | Committer name |
| `branch` | string | | Branch deployed |
| `triggered_by` | string | DEFAULT "manual" | manual/webhook/api |
| `cloud_build_id` | string | | GCP Cloud Build operation ID |
| `cloud_build_log_url` | string | | Direct link to build logs in Cloud Console |
| `image_url` | string | | Full Artifact Registry image URL with tag |
| `service_url` | string | | Cloud Run service URL (on success) |
| `error_message` | text | | Failure reason (on failure) |
| `started_at` | datetime | | Set when entering "cloning" |
| `finished_at` | datetime | | Set on success/failed/cancelled |
| `created_at` | datetime | NOT NULL | |
| `updated_at` | datetime | NOT NULL | |

**Indexes:** `project_id` (via `t.references`), `status`, `cloud_build_id`, `commit_sha`, `triggered_by`, `[project_id, status]` (composite), `created_at`

**Status lifecycle:**
```
pending → cloning → detecting → building → deploying → success
                                                      ↘ failed
                                                      ↘ cancelled
```

**Computed fields:**
- `duration_seconds` — `finished_at - started_at` (nil while running)
- `duration_label` — formatted as "2m 34s"
- `in_progress?` — status in `[pending, cloning, detecting, building, deploying]`
- `terminal?` — status in `[success, failed, cancelled]`

---

### `deployment_logs`

Append-only log lines produced by the deployment pipeline. Never updated.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigint | PK | |
| `deployment_id` | bigint | NOT NULL, FK → deployments | |
| `message` | text | NOT NULL | Log line content |
| `level` | string | NOT NULL, DEFAULT "info" | info/warn/error/debug |
| `source` | string | DEFAULT "system" | system/cloud_build/cloud_run |
| `logged_at` | datetime | NOT NULL | Wall-clock time of the event |
| `created_at` | datetime | NOT NULL | |
| `updated_at` | datetime | NOT NULL | |

**Indexes:** `deployment_id` (via `t.references`), `level`, `logged_at`, `[deployment_id, logged_at]` (composite — used for chronological queries)

**Notes:**
- Written via `Deployment#append_log` which also triggers the Turbo Stream broadcast
- The `[deployment_id, logged_at]` composite index covers the `chronological` scope query pattern
- `source` distinguishes system pipeline messages from raw Cloud Build / Cloud Run output

---

### `secrets`

Encrypted environment variables injected into Cloud Run at deploy time.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | bigint | PK | |
| `project_id` | bigint | NOT NULL, FK → projects | |
| `key` | string | NOT NULL | Must match `/\A[A-Z][A-Z0-9_]*\z/` |
| `encrypted_value` | text | NOT NULL | AES-256-CBC ciphertext (attr_encrypted) |
| `encrypted_value_iv` | string | NOT NULL | Initialization vector for ciphertext |
| `created_at` | datetime | NOT NULL | |
| `updated_at` | datetime | NOT NULL | |

**Indexes:** `[project_id, key]` (unique), `project_id` (via `t.references`)

**Notes:**
- Virtual attribute `value` is the plaintext accessor — decrypted on read, encrypted on write
- `masked_value` returns the first few chars followed by bullets for safe UI display
- Reserved keys (`PORT`, `HOST`, `RAILS_ENV`, `RACK_ENV`, `NODE_ENV`) are blocked at the model level
- `Secret.to_cloud_run_env_string(project)` formats all secrets as `KEY=value,KEY2=value2` for the `gcloud run deploy --set-env-vars` flag

---

## Conventions

### Encryption

Two columns use `attr_encrypted`:
- `users.github_token`
- `secrets.encrypted_value` + `secrets.encrypted_value_iv`

Both use the same key: `Rails.application.credentials.dig(:encryption, :key)`. This must be exactly 32 bytes (256 bits). Generate with:

```ruby
SecureRandom.hex(16)  # => 32-character hex string
```

### Soft Deletes

Not used in V1. Records are hard-deleted. Project deletion cascades to all deployments, logs, and secrets via `dependent: :destroy`.

### Timestamps

All tables use Rails standard `created_at` / `updated_at`. `deployment_logs` additionally has `logged_at` which reflects the actual wall-clock time of the event rather than the DB insert time (these may differ if inserts are batched).

### Scopes Reference

| Model | Scope | SQL |
|---|---|---|
| Project | `ordered` | `ORDER BY created_at DESC` |
| Project | `active` | `WHERE status = 'active'` |
| Deployment | `recent` | `ORDER BY created_at DESC` |
| Deployment | `in_progress` | `WHERE status IN (...)` |
| Deployment | `terminal` | `WHERE status IN (...)` |
| DeploymentLog | `chronological` | `ORDER BY logged_at ASC` |
| Secret | `ordered` | `ORDER BY key ASC` |
| Repository | `stale` | `WHERE last_synced_at < 1 hour ago OR NULL` |
