# Anchor

> Deploy any GitHub repository to Google Cloud Run — no Kubernetes, no YAML, no ops team required.

Anchor detects your framework, generates a production Dockerfile, submits the build to Cloud Build, streams logs live to your browser, and deploys to Cloud Run. If anything goes wrong, Claude explains the error in plain English.

**Your infrastructure. Your GCP bill. Anchor is just the control plane.**

---

## Table of Contents

- [How it works](#how-it-works)
- [Tech stack](#tech-stack)
- [Prerequisites](#prerequisites)
- [Local development](#local-development)
- [Environment variables](#environment-variables)
- [Architecture](#architecture)
- [Deployment pipeline](#deployment-pipeline)
- [Google Cloud setup](#google-cloud-setup)
- [Running tests](#running-tests)
- [Common tasks](#common-tasks)

---

## How it works

```
GitHub repo  →  Framework detection  →  Dockerfile generation
     ↓
Cloud Build  →  Container image  →  Artifact Registry
     ↓
Cloud Run  →  Live URL  →  Health check
     ↓
(on failure)  →  Claude explains what went wrong
```

1. Sign in with GitHub
2. Pick a repository — Anchor syncs your repos via the GitHub API
3. Connect a Google Cloud project (OAuth or service account key)
4. Add secrets (env vars) — encrypted at rest, injected at deploy time
5. Click **Deploy** — watch logs stream live in the browser
6. Get a Cloud Run URL

Auto-deploy on push is available via GitHub webhook. CI/CD workflow files can be generated and committed directly from the UI.

---

## Tech stack

| Layer | Technology |
|---|---|
| Framework | Ruby on Rails 8.1.2 |
| Ruby | 3.4.4 |
| Database | PostgreSQL 15+ |
| Background jobs | Sidekiq 8 + Redis 7 |
| Frontend | Hotwire (Turbo Streams + Stimulus) + Tailwind CSS v4 |
| Real-time | ActionCable over Redis |
| Auth | OmniAuth — GitHub OAuth2 + Google OAuth2 |
| GitHub API | Octokit 10 |
| Encryption | attr_encrypted (AES-256-CBC) |
| GCP clients | google-apis-run_v2, google-apis-cloudbuild_v1 |
| Token refresh | Signet |
| Rate limiting | Rack::Attack over Redis |
| Web server | Puma + Thrust (zero-downtime restarts) |
| AI | Anthropic Claude (Haiku) — error explanation + repo analysis |
| Testing | RSpec 7, Factory Bot, Shoulda Matchers, WebMock |

---

## Prerequisites

- Ruby 3.4.4 — use [rbenv](https://github.com/rbenv/rbenv) or [mise](https://mise.jdx.dev)
- PostgreSQL 15+
- Redis 7+
- [`gcloud` CLI](https://cloud.google.com/sdk/docs/install) — required at runtime for deployments
- A [GitHub OAuth App](https://github.com/settings/applications/new)
- A Google Cloud project with billing enabled (for testing deployments)

---

## Local development

### 1. Clone and install

```bash
git clone https://github.com/your-org/anchor.git
cd anchor
bundle install
```

### 2. Create a GitHub OAuth App

Go to **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**:

| Field | Value |
|---|---|
| Homepage URL | `http://localhost:3000` |
| Authorization callback URL | `http://localhost:3000/auth/github/callback` |

Copy the **Client ID** and **Client Secret**.

### 3. Create a Google OAuth App *(optional — needed for GCP integration)*

Go to [Google Cloud Console → APIs & Services → Credentials → Create OAuth client ID](https://console.cloud.google.com/apis/credentials):

| Field | Value |
|---|---|
| Application type | Web application |
| Authorized redirect URI | `http://localhost:3000/auth/google_oauth2/callback` |

### 4. Configure credentials

Generate a 32-byte encryption key:

```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(16)"
```

Edit the encrypted credentials file:

```bash
EDITOR="nano" bundle exec rails credentials:edit
```

Add the following structure:

```yaml
github:
  client_id: "YOUR_GITHUB_CLIENT_ID"
  client_secret: "YOUR_GITHUB_CLIENT_SECRET"

google:
  client_id: "YOUR_GOOGLE_CLIENT_ID"
  client_secret: "YOUR_GOOGLE_CLIENT_SECRET"

encryption:
  key: "your-32-byte-hex-key-here"

anthropic:
  api_key: "sk-ant-..."   # optional — AI features gracefully degrade without it
```

### 5. Database setup

```bash
createdb anchor_development
bundle exec rails db:migrate
```

### 6. Start the server

```bash
bin/dev
```

This runs two processes via Foreman:

| Process | Command |
|---|---|
| `web` | `bin/rails server` (port 3000) |
| `worker` | `bundle exec sidekiq -C config/sidekiq.yml` |

Open [http://localhost:3000](http://localhost:3000).

---

## Environment variables

All secrets live in `config/credentials.yml.enc` by default. Environment variables **override** credentials when both are set — useful for production / CI.

| Variable | Required | Description |
|---|---|---|
| `RAILS_MASTER_KEY` | ✅ | Contents of `config/master.key` |
| `DATABASE_URL` | ✅ | PostgreSQL connection string |
| `REDIS_URL` | ✅ | Redis connection string |
| `GITHUB_CLIENT_ID` | ✅ | GitHub OAuth app client ID |
| `GITHUB_CLIENT_SECRET` | ✅ | GitHub OAuth app client secret |
| `GOOGLE_CLIENT_ID` | — | Google OAuth app client ID |
| `GOOGLE_CLIENT_SECRET` | — | Google OAuth app client secret |
| `ENCRYPTION_KEY` | — | 32-byte AES-256 key for at-rest encryption |
| `ANTHROPIC_API_KEY` | — | Enables AI error explanation and repo analysis |
| `GITHUB_WEBHOOK_SECRET` | — | HMAC secret for verifying GitHub webhook payloads |
| `RAILS_LOG_TO_STDOUT` | — | Set `true` in production |
| `RAILS_SERVE_STATIC_FILES` | — | Set `true` when not behind a CDN |
| `RAILS_MAX_THREADS` | — | Puma threads (default: `5`) |
| `SIDEKIQ_CONCURRENCY` | — | Sidekiq workers (default: `10`) |

> **Note:** `ANTHROPIC_API_KEY` is optional. Repository analysis falls back to deterministic heuristics and error explanation is skipped if the key is absent.

---

## Architecture

### Models

| Model | Responsibility |
|---|---|
| `User` | Auth tokens (encrypted), GCP credentials, deployment quotas |
| `Repository` | GitHub repos synced via Octokit |
| `Project` | Cloud Run service definition, framework state, analysis results, CI/CD config |
| `Deployment` | Full lifecycle record — status, logs, error category, AI explanation, Cloud Build URL |
| `DeploymentLog` | Append-only build/deploy log lines, streamed live via Turbo |
| `DeploymentEvent` | Audit trail of every status transition |
| `Secret` | Encrypted env vars per project, injected into Cloud Run at deploy time |

### Status machine

```
queued → pending → analyzing → cloning → detecting
       → building → deploying → health_check
       → running | success | failed | cancelled
```

Terminal states: `running`, `success`, `failed`, `cancelled`.

### Key services

| Service | What it does |
|---|---|
| `FrameworkDetector` | Heuristic detection: Rails, Next.js, FastAPI, Flask, Django, Go, Elixir, Bun, static, Docker |
| `DockerfileGenerator` | Per-framework production Dockerfile templates; `self.preview` for UI rendering |
| `RepositoryAnalyzer` | Deterministic analysis — dependencies, env vars, database detection |
| `Services::Ai::RepositoryAnalyzer` | Claude enrichment on top of deterministic results |
| `Services::Ai::ErrorExplainer` | 2–4 sentence plain-English failure explanation |
| `Services::Deployments::ErrorCategorizer` | Maps build errors to 13 named categories with user hints |
| `Services::Gcp::ApiEnabler` | Enables Cloud Build / Cloud Run / Artifact Registry APIs |
| `Services::Gcp::ArtifactRegistryProvisioner` | Creates per-region Docker repository |

### Real-time updates

Every deployment streams two Turbo Stream channels:

| Channel | What it carries |
|---|---|
| `deployment_<id>` | Status badge, pipeline steps, outcome panel, error message |
| `deployment_<id>_logs` | Individual log lines appended into the terminal UI |
| `deployment_<id>_events` | Timeline events (status transitions) |
| `project_<id>_deployments` | Deployment row prepend and status badge updates |

---

## Deployment pipeline

Five Sidekiq jobs execute in sequence. Each hands off to the next only on success. Any failure stops the chain, marks the deployment `failed`, and enqueues the error explainer.

```
DeploymentJob
  └─ Deployments::PrepareJob          # clone repo, detect framework, generate Dockerfile
       └─ Deployments::BuildImageJob  # gcloud builds submit --async
            └─ Deployments::PollBuildStatusJob   # exponential backoff, 15–60s intervals
                 └─ Deployments::DeployToCloudRunJob  # gcloud run deploy + health check
                      └─ ExplainErrorJob  # (only on failure) Anthropic Haiku
```

**Authentication for gcloud commands:** OAuth token (`CLOUDSDK_AUTH_ACCESS_TOKEN`) is preferred; falls back to a temporary service account key file.

---

## Google Cloud setup

### Automatic (recommended)

When a project is created in Anchor, `Gcp::ProvisionProjectJob` runs automatically and:

1. Enables Cloud Build, Cloud Run, and Artifact Registry APIs
2. Creates a Docker repository in Artifact Registry (`anchor-images`)

This requires the connected Google account to have **Owner** or **Editor** role on the GCP project.

### Manual

```bash
PROJECT_ID="your-gcp-project-id"
REGION="us-central1"

# Enable APIs
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  --project=$PROJECT_ID

# Create Artifact Registry repo
gcloud artifacts repositories create anchor-images \
  --repository-format=docker \
  --location=$REGION \
  --project=$PROJECT_ID
```

### Deploying Anchor itself to Cloud Run

```bash
IMAGE="gcr.io/$PROJECT_ID/anchor:latest"

# Build
gcloud builds submit --tag=$IMAGE

# Run migrations
gcloud run jobs create anchor-migrate \
  --image=$IMAGE \
  --command="bundle,exec,rails,db:migrate" \
  --set-env-vars="RAILS_MASTER_KEY=$RAILS_MASTER_KEY,DATABASE_URL=$DATABASE_URL"
gcloud run jobs execute anchor-migrate --wait

# Web process
gcloud run deploy anchor-web \
  --image=$IMAGE \
  --command="./bin/thrust,./bin/rails,server,-b,0.0.0.0,-p,8080" \
  --port=8080 \
  --set-env-vars="RAILS_MASTER_KEY=$RAILS_MASTER_KEY,DATABASE_URL=$DATABASE_URL,REDIS_URL=$REDIS_URL"

# Sidekiq worker
gcloud run deploy anchor-worker \
  --image=$IMAGE \
  --command="bundle,exec,sidekiq,-C,config/sidekiq.yml" \
  --no-cpu-throttling \
  --set-env-vars="RAILS_MASTER_KEY=$RAILS_MASTER_KEY,DATABASE_URL=$DATABASE_URL,REDIS_URL=$REDIS_URL"
```

---

## Running tests

```bash
bundle exec rspec                     # full suite
bundle exec rspec spec/models         # models only
bundle exec rspec spec/jobs           # jobs only
bundle exec rspec spec/services       # services only
```

The test suite uses WebMock to stub all external HTTP — no real GitHub or GCP calls are made during testing.

---

## Common tasks

```bash
# Rails console
bin/rails console

# Inspect Sidekiq queues
bin/rails runner "puts Sidekiq::Queue.all.map { |q| '#{q.name}: #{q.size}' }"

# Manually trigger a deployment
bin/rails runner "DeploymentJob.perform_later(Deployment.last.id)"

# View failed jobs
bin/rails runner "Sidekiq::DeadSet.new.each { |j| puts j.item }"

# Reset a stuck deployment
bin/rails runner "Deployment.find(ID).update!(status: 'failed')"

# Re-analyze a project
bin/rails runner "RepositoryAnalysisJob.perform_later(Project.find(ID).id)"

# Rotate the encryption key (requires re-encrypting all secrets)
# 1. Update ENCRYPTION_KEY / credentials.yml.enc
# 2. Re-save all secrets and tokens via a migration
```

---

## Rate limits

Rack::Attack enforces the following limits (Redis-backed):

| Endpoint | Limit |
|---|---|
| All requests | 300 req / 5 min per IP |
| OAuth callbacks | 10 req / 20 min per IP |
| Deploy action | 20 req / hour per user |
| Analyze action | 30 req / hour per user |
| Repo sync | 10 req / 10 min per user |

Per-user deployment quotas are also enforced at the model layer: **20 deploys/day**, **200 deploys/month**.

---

## Security

- All OAuth tokens and secrets are encrypted at rest with AES-256-CBC via `attr_encrypted`
- The encryption key never touches the database
- Google OAuth tokens are refreshed automatically when within 5 minutes of expiry
- GitHub webhook payloads are verified with HMAC-SHA256 (`X-Hub-Signature-256`)
- Temporary GCP credential files are written to `Tempfile` and deleted immediately after use
- CSRF protection is enabled on all non-webhook endpoints

---

## Contributing

1. Fork the repo and create a branch: `git checkout -b feature/my-feature`
2. Make your changes with tests
3. Ensure the suite passes: `bundle exec rspec`
4. Open a pull request against `main`

Please keep PRs focused. One feature or fix per PR.
