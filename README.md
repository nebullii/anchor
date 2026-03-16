# Anchor

Deploy any GitHub repository to Google Cloud Run. Anchor handles framework detection, Dockerfile generation, Cloud Build image builds, and Cloud Run deployments — with live log streaming to the browser the entire time.

No Kubernetes. No YAML to write. Click Deploy, watch it go.

---

## What it does

1. Sign in with GitHub
2. Pick a repository
3. Set environment variables
4. Click Deploy
5. Watch the build stream live
6. Get a Cloud Run URL

Anchor detects your framework, generates a Dockerfile if you don't have one, submits the build to Cloud Build, polls until it finishes, then deploys to Cloud Run and health-checks the service. If anything goes wrong, Claude explains what happened in plain English.

---

## System Design

```
┌─────────────────────────────────────────────────────────────────────┐
│  Browser                                                            │
│  Turbo Drive navigation · Turbo Streams (live updates) · Stimulus  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ HTTP / WebSocket (ActionCable)
┌───────────────────────────────▼─────────────────────────────────────┐
│  Rails 8.1 (Puma / Thrust)                                          │
│                                                                     │
│  Auth: GitHub OAuth ──► OmniAuth ──► session[:user_id]             │
│         Google OAuth ──► OmniAuth ──► user.google_access_token      │
│                                                                     │
│  Controllers ──► Sidekiq Jobs ──► gcloud CLI                        │
│  Turbo Streams ──► ActionCable ──► Redis pub/sub                    │
└──────┬────────────────────────────────────────┬──────────────────────┘
       │ PostgreSQL                             │ Redis
       │ (users, projects,                      │ (Sidekiq queues,
       │  deployments, logs,                    │  ActionCable,
       │  secrets)                              │  Rack::Attack)
       └────────────────────────────────────────┘

Sidekiq Deployment Pipeline (5 jobs, no retries):

DeploymentJob
  └─ PrepareJob          git clone · detect framework · generate Dockerfile
      └─ BuildImageJob   gcloud builds submit --async
          └─ PollBuildStatusJob   polls every 15–60s (exponential backoff, 40 attempts max)
              └─ DeployToCloudRunJob   gcloud run deploy · health check · save URL

On any failure → ExplainErrorJob (async)
                  └─ Anthropic Haiku → plain-English explanation → broadcast to browser

GCP per deployment:
  Cloud Build ──► Artifact Registry ──► Cloud Run
```

### Data model

```
User
├─ has_many :repositories      (GitHub-synced, read from Octokit)
└─ has_many :projects
     ├─ has_many :deployments
     │    └─ has_many :deployment_logs   (append-only, ~200 lines/deploy)
     └─ has_many :secrets               (encrypted env vars)
```

All tokens and secrets are encrypted at rest with `attr_encrypted` (AES-256-CBC). The encryption key never touches the database.

### Auth flow

```
GitHub OAuth  →  sign in, stores github_token (encrypted)
Google OAuth  →  connects GCP access, stores access + refresh tokens (encrypted)
               ↕  token auto-refreshed via Signet when < 5 minutes from expiry
Service Account Key  →  fallback / advanced: JSON pasted in Settings, stored encrypted
```

Deployments use whichever credential is available: OAuth token via `CLOUDSDK_AUTH_ACCESS_TOKEN`, or service account key written to a temp file for the gcloud subprocess lifetime only.

---

## Stack

| Layer | Technology |
|---|---|
| Framework | Ruby on Rails 8.1 |
| Database | PostgreSQL 15+ |
| Background jobs | Sidekiq 8 + Redis 7 |
| Frontend | Hotwire (Turbo + Stimulus) + Tailwind CSS v4 |
| Real-time | ActionCable over Redis |
| Auth | OmniAuth (GitHub + Google OAuth2) |
| GCP APIs | Cloud Build, Cloud Run, Artifact Registry |
| Token management | Signet (OAuth2 refresh) |
| Encryption | attr_encrypted (AES-256-CBC) |
| Rate limiting | Rack::Attack (Redis-backed) |
| AI features | Anthropic API — claude-haiku-4-5 (optional, gracefully degraded) |
| Web server | Puma + Thrust (zero-downtime restarts) |
| Tests | RSpec 7, Factory Bot, Shoulda Matchers, WebMock (260 examples) |

---

## Framework Detection

Anchor inspects the repository root in priority order:

| Framework | Signal | Default port |
|---|---|---|
| docker | `Dockerfile` present | 8080 |
| rails | `Gemfile` contains `rails` | 3000 |
| nextjs | `package.json` depends on `next` | 3000 |
| bun | `bun.lockb` or `bun.lock` present | 3000 |
| node | `package.json` present | 3000 |
| fastapi | `requirements.txt` contains `fastapi` | 8000 |
| flask | `requirements.txt` contains `flask` | 5000 |
| django | `requirements.txt` contains `django` | 8000 |
| python | `requirements.txt` / `pyproject.toml` | 8000 |
| go | `go.mod` present | 8080 |
| elixir | `mix.exs` present | 4000 |
| static | `index.html` in root | 80 |

If no Dockerfile is found, one is generated from a hardcoded template for the detected framework. Ruby version, Node version, Python entry point, Go module, and Elixir app name are all extracted and threaded into the template.

---

## Local Development

### Prerequisites

- Ruby 3.4.4
- PostgreSQL 15+
- Redis 7+
- `gcloud` CLI on `$PATH`
- A GitHub OAuth App

### Setup

```bash
git clone https://github.com/your-org/anchor.git
cd anchor
bundle install
```

**Create a GitHub OAuth App** at [github.com/settings/applications/new](https://github.com/settings/applications/new):

| Field | Value |
|---|---|
| Homepage URL | `http://localhost:3000` |
| Authorization callback URL | `http://localhost:3000/auth/github/callback` |

**Edit credentials:**

```bash
EDITOR="nano" bundle exec rails credentials:edit
```

```yaml
github:
  client_id: "YOUR_GITHUB_CLIENT_ID"
  client_secret: "YOUR_GITHUB_CLIENT_SECRET"

google:
  client_id: "YOUR_GOOGLE_CLIENT_ID"       # optional — enables Connect Google Cloud
  client_secret: "YOUR_GOOGLE_CLIENT_SECRET"

encryption:
  key: "32-byte-string-exactly-32-chars!!"
```

Generate a 32-byte encryption key: `ruby -e "require 'securerandom'; puts SecureRandom.hex(16)"`

**Database:**

```bash
createdb anchor_development
bundle exec rails db:migrate
```

**Start:**

```bash
bin/dev
```

Three processes via Foreman:

| Process | Command |
|---|---|
| `web` | `bin/rails server -p 3000` |
| `css` | `bin/rails tailwindcss:watch` |
| `worker` | `bundle exec sidekiq -C config/sidekiq.yml` |

---

## Google Cloud Setup

Each project deploys into **the user's own GCP project** — not Anchor's. Before a user can deploy, their target GCP project needs these APIs enabled and an Artifact Registry repository created. Anchor's `ProvisionProjectJob` handles this automatically on first project creation.

To do it manually:

```bash
PROJECT_ID=your-gcp-project-id

gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  --project=$PROJECT_ID

gcloud artifacts repositories create anchor \
  --repository-format=docker \
  --location=us-central1 \
  --project=$PROJECT_ID
```

### Connecting Google Cloud

Users connect their GCP account from the Settings page in two ways:

**Option 1 — Google OAuth (recommended):** Click "Connect Google Cloud". Grants `cloud-platform` scope. Access tokens are auto-refreshed via the stored refresh token. No files to manage.

**Option 2 — Service Account Key (advanced):** Paste the JSON key from a service account with these roles:

| Role | Purpose |
|---|---|
| `roles/cloudbuild.builds.editor` | Submit and read builds |
| `roles/run.admin` | Create and update Cloud Run services |
| `roles/artifactregistry.writer` | Push container images |
| `roles/storage.admin` | Upload source to GCS for Cloud Build |
| `roles/iam.serviceAccountUser` | Allow Cloud Build to act as the runtime service account |

---

## Environment Variables

### Required

| Variable | Description |
|---|---|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `RAILS_MASTER_KEY` | Contents of `config/master.key` |

### Optional

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Enables repo analysis enrichment and AI error explanation. If unset, both features are silently skipped. |
| `GITHUB_CLIENT_ID` | credentials | GitHub OAuth app client ID |
| `GITHUB_CLIENT_SECRET` | credentials | GitHub OAuth app client secret |
| `GOOGLE_CLIENT_ID` | credentials | Google OAuth app client ID |
| `GOOGLE_CLIENT_SECRET` | credentials | Google OAuth app client secret |
| `ENCRYPTION_KEY` | credentials | 32-byte AES-256 key for attr_encrypted |
| `RAILS_MAX_THREADS` | `5` | Puma thread count + DB pool size |
| `SIDEKIQ_CONCURRENCY` | `10` | Sidekiq worker threads |
| `RAILS_LOG_TO_STDOUT` | — | Set to `true` in production |
| `RAILS_SERVE_STATIC_FILES` | — | Set to `true` in production |

Credentials (OAuth keys, encryption key) live in `config/credentials.yml.enc`. The environment variables override credentials when both are set.

---

## Project Structure

```
app/
├── channels/
│   └── deployment_log_channel.rb       ActionCable — authenticates and subscribes
├── controllers/
│   ├── application_controller.rb       require_login, current_user
│   ├── auth_controller.rb              GitHub + Google OAuth callbacks, disconnect
│   ├── projects_controller.rb          CRUD, deploy, analyze, CI/CD
│   ├── deployments_controller.rb       show (live terminal), create, cancel
│   ├── secrets_controller.rb           add/remove encrypted env vars
│   ├── repositories_controller.rb      list + sync from GitHub
│   └── settings_controller.rb          GCP credentials
├── javascript/controllers/
│   ├── log_controller.js               auto-scroll, line count, elapsed timer
│   ├── deploy_controller.js            loading state on Deploy button
│   ├── clipboard_controller.js         copy URL to clipboard
│   └── flash_controller.js             auto-dismiss flash messages (5s)
├── jobs/
│   ├── deployment_job.rb               pipeline entry point
│   ├── repository_analysis_job.rb      deterministic + AI analysis
│   └── deployments/
│       ├── base_job.rb                 shared error handling, run_gcloud!
│       ├── prepare_job.rb              clone, detect, generate Dockerfile
│       ├── build_image_job.rb          Cloud Build submit
│       ├── poll_build_status_job.rb    exponential backoff polling
│       ├── deploy_to_cloud_run_job.rb  gcloud run deploy + health check
│       └── explain_error_job.rb        async AI failure explanation
├── models/
│   ├── user.rb                         OAuth tokens (encrypted), quotas, GCP helpers
│   ├── repository.rb                   synced from GitHub API
│   ├── project.rb                      one project = one Cloud Run service
│   ├── deployment.rb                   status machine, Turbo broadcasts
│   ├── deployment_log.rb               append-only log lines
│   └── secret.rb                       encrypted env vars per project
└── services/
    ├── framework_detector.rb           file-presence heuristics
    ├── dockerfile_generator.rb         per-framework templates
    ├── repository_analyzer.rb          orchestrates deterministic analysis
    ├── analysis/
    │   ├── dependency_reader.rb        reads from lockfiles
    │   ├── env_var_detector.rb         detects likely env vars from source
    │   └── database_detector.rb        postgres, mysql, sqlite, mongodb, redis
    ├── ai/
    │   ├── repository_analyzer.rb      Claude enrichment on top of deterministic result
    │   └── error_explainer.rb          2–4 sentence plain-English failure explanation
    ├── deployments/
    │   └── error_categorizer.rb        maps error strings to 13 named categories
    └── gcp/
        ├── api_enabler.rb              enables Cloud Build / Run / AR APIs
        └── artifact_registry_provisioner.rb  creates the docker repo
```

---

## Real-Time Updates

No custom WebSocket code. All live updates are Turbo Streams broadcast from model callbacks and job methods:

| Trigger | Stream | Browser effect |
|---|---|---|
| `deployment.append_log` | `deployment_#{id}_logs` | Log line appended to terminal |
| `deployment.transition_to!` | `deployment_#{id}` | Status badge replaced |
| Terminal state reached | `deployment_#{id}` (outcome) | Service URL or error panel appears |
| Terminal state reached | `deployment_#{id}_logs` | Spinner removed |

The `log` Stimulus controller uses a `MutationObserver` to auto-scroll the terminal as Turbo appends lines, pausing when the user scrolls up.

ActionCable uses the async adapter in development and Redis in production. Both are configured in `config/cable.yml`.

---

## Deploying Anchor to Cloud Run

Build the image, then run two Cloud Run services from it — one for web, one for Sidekiq:

```bash
# Build
gcloud builds submit --tag=IMAGE_URL

# Migrations
gcloud run jobs create anchor-migrate \
  --image=IMAGE_URL \
  --command="bundle,exec,rails,db:migrate"
gcloud run jobs execute anchor-migrate

# Web
gcloud run deploy anchor-web \
  --image=IMAGE_URL \
  --command="./bin/thrust,./bin/rails,server,-b,0.0.0.0,-p,8080" \
  --set-env-vars="RAILS_MASTER_KEY=...,DATABASE_URL=...,REDIS_URL=..."

# Worker
gcloud run deploy anchor-worker \
  --image=IMAGE_URL \
  --command="bundle,exec,sidekiq,-C,config/sidekiq.yml" \
  --set-env-vars="RAILS_MASTER_KEY=...,DATABASE_URL=...,REDIS_URL=..."
```

The `Dockerfile` is a multi-stage build: asset compilation and gem installation in a build stage, then a minimal runtime image with jemalloc and the `gcloud` CLI baked in (required by Sidekiq workers).

---

## Security

**Encrypted at rest (AES-256-CBC via attr_encrypted):**

| Field | Model |
|---|---|
| `github_token` | User |
| `google_access_token` | User |
| `google_refresh_token` | User |
| `gcp_service_account_key` | User |
| Secret `value` | Secret |

All use the key at `credentials.dig(:encryption, :key)`. Rotating the key requires re-encrypting all records first.

**Rate limiting (Rack::Attack, Redis-backed):**

| Throttle | Limit |
|---|---|
| General requests | 300 req / 5 min per IP |
| OAuth callbacks | 10 attempts / 20 min per IP |
| Deploys | 20 / hour per user |
| Analyze | 30 / hour per user |
| Repo sync | 10 / 10 min per user |

**Deployment quotas** are also enforced at the model level: 20 deploys/day and 200/month per user, tracked in `deployments_today` / `deployments_this_month` with a midnight reset.

---

## Tests

```bash
bundle exec rspec
```

260 examples covering models, jobs, services, and controllers. The test suite uses WebMock to stub all external HTTP, Factory Bot for fixtures, and Shoulda Matchers for model assertions.

---

## Common Tasks

```bash
# Start development
bin/dev

# Rails console
bundle exec rails console

# Check Sidekiq queue depth
bundle exec rails runner "Sidekiq::Queue.all.each { |q| puts \"#{q.name}: #{q.size}\" }"

# Manually trigger a deployment
deployment = Project.find(ID).deployments.create!(
  status: "pending", triggered_by: "manual", branch: "main"
)
DeploymentJob.perform_later(deployment.id)

# Inspect encrypted value
secret = Secret.find(ID)
puts secret.value           # decrypted
puts secret.encrypted_value # ciphertext
```

---

## Contributing

1. Branch from `main`
2. Make changes
3. `bundle exec rails runner "puts 'OK'"` — verify boot
4. `bundle exec rspec` — verify tests pass
5. Open a pull request
