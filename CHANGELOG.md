# Changelog

All notable changes to Anchor. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Anchor is in beta, and minor versions may include
breaking changes.

## [0.2.0] — 2026-09-27

This release is about safe releases, a provider abstraction, and interfaces for agents. See
[README → Status and known gaps](README.md#status-and-known-gaps) for what is still missing.

### Deployment pipeline and state machine
- New `superseded` status: when a deployment goes live, older live deployments are marked `superseded`, so exactly one deployment per project reads `running`. The one-active-deploy index now lists in-progress statuses, so new finished statuses no longer need a migration. A failed deploy no longer marks the project `error` while an older revision is still serving.
- `Deployment::TRANSITIONS` is now an explicit state machine. `transition_to!` row-locks the
  deployment and raises `Deployment::InvalidTransition` on an illegal move. New status: `rolled_back`.
  New triggers: `cli` and `rollback`.
- A partial unique index allows only one active deployment per project. Every deploy entry point
  (web, wizard, API, redeploy) goes through `Deployments::Starter`, which reserves quota atomically and
  handles the race.
- Transient errors are retried a bounded number of times, and the deployment is marked failed when
  retries run out. Before this change it could get stuck forever.
- New `Deployments::ReaperJob`, which runs every 5 minutes. It fails deployments stuck in one status
  past a timeout (for example 45 minutes in `building`) and cancels their builds.
- `cancel!` now stops the build too: `gcloud builds cancel`, or SIGTERM to `docker build`.
- The pipeline is stateless across workers. Clone, detect, preflight, Dockerfile generation, and build
  submission all happen in `PrepareJob`, so no local path crosses a job boundary. `BuildImageJob` is
  now a deprecation shim.
- Monorepo support: the build context is the app's `root_dir`.

### Safe rollouts and rollback
- New revisions start **without traffic**. `HealthCheckJob` probes the revision URL with backoff
  (8 attempts over 150 s by default, set with `HEALTH_CHECK_ATTEMPTS` and
  `HEALTH_CHECK_BUDGET_SECONDS`) and promotes only on success. On failure the revision is deleted, the
  previous one keeps serving, and the deployment fails with category `health_check`. Proxy error pages
  such as the Google Frontend 404 are not counted as healthy.
- One-click rollback (`Deployments::Rollback` and `RollbackJob`) moves traffic to an earlier healthy
  revision without rebuilding. It is available as a button, `POST /projects/:id/rollback`, the API,
  the CLI, and MCP.

### Providers
- New `Providers::Base` interface and registry (`Providers.for(project)`), with
  `Providers::GcpCloudRun` and a new, free **`Providers::LocalDocker`** provider.
- Every subprocess goes through `Providers::CommandRunner` (argv arrays, redaction, PID capture).
- New project columns: `provider`, `memory`, `health_check_path`, `public_access`. New deployment
  columns: `revision_name`, `revision_url`, `build_ref`. Cloud Run now honors `public_access`
  instead of always passing `--allow-unauthenticated`.

### Static analysis and preflight
- Framework detection now parses manifests (package.json, Gemfile/Gemfile.lock, requirements,
  pyproject/TOML, go.mod, mix.exs, Dockerfile) instead of only checking which files exist.
- New `Analysis::Preflight` with 34 rules ([docs/preflight.md](docs/preflight.md)). Error findings
  block the deploy before the build starts. Findings appear in the analysis panel, the API, and
  `anchor doctor`.
- Hardened Dockerfile templates, plus fixture repos with golden Dockerfiles.

### API, CLI, and MCP
- MCP tools accept a project slug as well as a numeric id, and cap secret values at the server's 32 KiB limit. The project JSON now includes `memory`, `health_check_path`, `public_access` and `root_dir`.
- New token-authenticated JSON API at `/api/v1` ([docs/api.md](docs/api.md)) with a consistent error
  envelope. Personal API tokens (`anc_…`, SHA-256 digest, revocable) are managed under
  Settings → API tokens.
- New `anchor` Go CLI ([docs/cli.md](docs/cli.md)): `login`, `whoami`, `projects`, `link`, `status`,
  `deploy -f`, `logs -f`, `cancel`, `rollback`, `secrets`, and `doctor`. Its exit codes work as a CI gate.
- New dependency-free MCP server with 11 tools ([docs/mcp.md](docs/mcp.md)).

### Security
- `projects.webhook_secret` is encrypted at rest; a data migration encrypts existing plaintext values in place.
- App secrets moved to Active Record Encryption (AES-256-GCM) with legacy CBC dual-read and
  `Secret.reencrypt_legacy!`. Secrets also get an audit log and a size limit. Project webhook secrets
  are encrypted too.
- New `Security::Redactor`. It is applied to every deployment log line and to text sent to the LLM.
  ANSI escape codes are stripped from logs.
- `.git` is removed after cloning, so the clone token can't end up in the build context or the image.
- Webhooks: per-project HMAC through `/webhooks/github?project=<slug>`, delivery dedupe, 4xx on bad
  input. The global secret now requires opting in.
- The CSP is enforced with nonces. Also new: secure session cookies, HSTS, the `APP_HOSTS` host
  allowlist, session reset on login and logout, and sanitized `return_to`.
- Rack::Attack: probes and webhooks are exempt, API throttles are per token, and throttled API
  responses return JSON 429s.
- LLM-generated CI/CD files must pass `Security::GeneratedFilePolicy` before they are committed.
- Patch-level gem updates. `bundle-audit` is clean.
- Added [SECURITY.md](SECURITY.md) and [docs/threat-model.md](docs/threat-model.md).

### AI
- Provider-agnostic client (`ANCHOR_AI_PROVIDER` = `anthropic` | `openai` | `none`) with structured
  outputs and redaction. Every AI feature is optional and does nothing without a key.
- Offline eval harness with 14 failure fixtures (`bin/rails anchor:ai_eval`, which costs money when
  run against a real model).

### CI/CD
- `script/e2e_local.sh` runs the whole product on every PR (web + Sidekiq + Docker + CLI): deploy, a
  broken release that must not take traffic, rollback, a preflight block, cancel mid-build and a signed
  webhook push.
- Production and staging deploys reuse the PR CI as their gate, then deploy Anchor itself the way it
  deploys apps: a no-traffic revision, a smoke test on its tagged URL, a traffic shift, verification and
  automatic rollback. Production waits for approval through a GitHub Environment.
- Deploys to GCP are opt-in (`ANCHOR_DEPLOY_ENABLED=true`), so merging never starts cloud spend.
- Keyless GCP auth with Workload Identity Federation (the JSON key remains as a fallback).
- CI blocks migrations that would break the revision still serving (`script/check_migrations.rb`).
- `release.yml` publishes CLI binaries, the MCP package and checksums when a `v*` tag is pushed.

### Operations
- New `/healthz` (liveness) and `/readyz` (database, Redis, Sidekiq, and queue latency) endpoints.
  Sidekiq Web is available to admins only (`ANCHOR_ADMIN_GITHUB_LOGINS`).
- The Cloud Run worker now runs with `--min-instances=1` so queued jobs can't hang. This costs roughly
  $45–55 per month per environment. Runtime secrets for Anchor itself now come from Secret Manager
  (`--set-secrets`). See [SETUP_GCLOUD.md](SETUP_GCLOUD.md).
- Added [docs/runbook.md](docs/runbook.md) and [docs/slo.md](docs/slo.md).

### Developer experience
- `bin/setup` is idempotent, with prerequisite checks. New `docker-compose.yml` full stack, a
  `Makefile`, `.env.example`, a dev login, and a seeded `hello-anchor` demo project on Local Docker.
- The minitest suite was migrated to RSpec. The suite is now 1,003 examples. CI runs RSpec, RuboCop,
  Brakeman, bundle-audit, the `bin/setup` idempotency check, `go test -race`, and `npm test`.

### Documentation
- Rewrote the README. Removed stale claims: the code did not use Claude only, there is no
  "ProviderAdapter", and secrets are no longer only AES-256-CBC.
- Added a quickstart, CLI, MCP, API, providers, preflight, and comparison docs, plus CONTRIBUTING.md.

## [0.1.0]

Initial public version: GitHub OAuth, framework detection, Dockerfile generation, Cloud Build →
Cloud Run deploys, live log streaming, webhook auto-deploy, AI error explanations, and deploy quotas.
