# Anchor

Deploy GitHub repositories to Google Cloud Run from a web UI.

Anchor handles framework detection, Docker image builds, Cloud Run deployments, and live log streaming — without any manual infrastructure configuration.

---

## What it does

1. Sign in with GitHub
2. Connect a repository
3. Set environment variables
4. Click Deploy
5. Watch the build log stream live in the browser
6. Get a Cloud Run URL when it's done

Supported frameworks: **Rails, Node.js, Python, static sites**, and any repo with an existing **Dockerfile**.

---

## Stack

| Layer | Technology |
|---|---|
| Backend | Ruby on Rails 8.1 |
| Database | PostgreSQL |
| Background jobs | Sidekiq + Redis |
| Frontend | Hotwire (Turbo + Stimulus) + Tailwind CSS v4 |
| Auth | GitHub OAuth (OmniAuth) |
| Build | Google Cloud Build |
| Deploy target | Google Cloud Run |
| Image registry | Google Artifact Registry |
| Encryption | attr_encrypted (AES-256-CBC) |

---

## Local Development

### Prerequisites

- Ruby 3.4.4 (`rbenv install 3.4.4`)
- PostgreSQL 15+
- Redis 7+
- Google Cloud SDK (`gcloud` CLI)
- A GitHub OAuth App

### 1. Clone and install

```bash
git clone https://github.com/your-org/anchor.git
cd anchor
bundle install
```

### 2. Create a GitHub OAuth App

Go to [github.com/settings/applications/new](https://github.com/settings/applications/new):

| Field | Value |
|---|---|
| Application name | Anchor (local) |
| Homepage URL | `http://localhost:3000` |
| Authorization callback URL | `http://localhost:3000/auth/github/callback` |

Copy the **Client ID** and **Client Secret**.

### 3. Configure credentials

```bash
EDITOR="nano" bundle exec rails credentials:edit
```

Add:

```yaml
github:
  client_id: "YOUR_CLIENT_ID"
  client_secret: "YOUR_CLIENT_SECRET"

encryption:
  key: "32-byte-string-exactly-32-chars!!"
```

The encryption key must be exactly 32 bytes. Generate one with:

```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(16)"
```

### 4. Set up the database

```bash
createdb anchor_development
bundle exec rails db:migrate
```

### 5. Authenticate with Google Cloud

```bash
gcloud auth login
gcloud auth application-default login
```

The deployer uses Application Default Credentials. The `gcloud` CLI must be on `$PATH` for Sidekiq workers.

### 6. Start the app

```bash
bin/dev
```

This starts three processes via Foreman:

| Process | Command |
|---|---|
| `web` | `bin/rails server` on port 3000 |
| `css` | `bin/rails tailwindcss:watch` |
| `worker` | `bundle exec sidekiq -C config/sidekiq.yml` |

Visit [http://localhost:3000](http://localhost:3000).

---

## Environment Variables

### Required at runtime

| Variable | Description |
|---|---|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `RAILS_MASTER_KEY` | Contents of `config/master.key` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to GCP service account JSON |

### Optional

| Variable | Default | Description |
|---|---|---|
| `RAILS_MAX_THREADS` | `5` | Puma thread count + DB pool size |
| `SIDEKIQ_CONCURRENCY` | `10` | Sidekiq worker thread count |
| `RAILS_LOG_TO_STDOUT` | — | Set to `true` in production |
| `RAILS_SERVE_STATIC_FILES` | — | Set to `true` in production |

Credentials (GitHub OAuth keys, encryption key) live in `config/credentials.yml.enc`, not in environment variables.

---

## GCP Setup

Each project deployment runs in **the user's own GCP project** — not Anchor's. Before deploying a project, the target GCP project needs:

### Enable APIs

```bash
gcloud services enable cloudbuild.googleapis.com --project=YOUR_PROJECT_ID
gcloud services enable run.googleapis.com --project=YOUR_PROJECT_ID
gcloud services enable artifactregistry.googleapis.com --project=YOUR_PROJECT_ID
```

### Create Artifact Registry repository

```bash
gcloud artifacts repositories create cloudlaunch \
  --repository-format=docker \
  --location=us-central1 \
  --project=YOUR_PROJECT_ID
```

### Required IAM roles for the service account

| Role | Purpose |
|---|---|
| `roles/cloudbuild.builds.editor` | Submit and read builds |
| `roles/run.admin` | Create and update Cloud Run services |
| `roles/artifactregistry.writer` | Push container images |
| `roles/storage.admin` | Upload source to GCS for Cloud Build |
| `roles/iam.serviceAccountUser` | Allow Cloud Build to act as runtime SA |

The `scripts/setup_gcloud.sh` script automates these steps.

---

## Deployment Pipeline

Every deploy runs a 5-job Sidekiq pipeline:

```
DeploymentJob          validates state, enqueues PrepareJob
  └─ PrepareJob        git clone → framework detect → generate Dockerfile
      └─ BuildImageJob gcloud builds submit --async → saves build ID
          └─ PollBuildStatusJob  polls every 15–60s with backoff (max 40 attempts)
              └─ DeployToCloudRunJob  gcloud run deploy → saves service URL
```

**Status transitions:**
```
pending → cloning → detecting → building → deploying → success
                                                      ↘ failed
                                                      ↘ cancelled
```

Each transition broadcasts a Turbo Stream that updates the status badge and outcome panel in the browser without a page reload.

### Framework detection

| Framework | Signal | Runtime | Port |
|---|---|---|---|
| docker | `Dockerfile` exists | custom | 8080 |
| rails | `Gemfile` contains "rails" | ruby3.2 | 3000 |
| node | `package.json` exists | node20 | 3000 |
| nextjs | `package.json` depends on `next` | node20 | 3000 |
| fastapi | `requirements.txt` contains `fastapi` | python3.11 | 8000 |
| flask | `requirements.txt` contains `flask` | python3.11 | 8000 |
| django | `requirements.txt` contains `django` | python3.11 | 8000 |
| python | `requirements.txt` or `pyproject.toml` | python3.11 | 8000 |
| static | `index.html` in root | nginx | 80 |

If no Dockerfile exists, one is generated from a hardcoded template for the detected framework. The generated file is written into the cloned repo before Cloud Build receives the source.

---

## AI Layer

Two AI-powered features run on top of the deterministic pipeline, both using `claude-haiku-4-5-20251001` via the Anthropic API. Both degrade gracefully — if `ANTHROPIC_API_KEY` is unset or the API call fails, the deploy continues unchanged.

### Repository analysis enrichment

Before the first deploy, `RepositoryAnalysisJob` clones the repo and runs a two-phase analysis:

1. **Deterministic** (`RepositoryAnalyzer`) — detects framework, runtime, port, likely env vars, database type, and dependency list from file contents
2. **AI enrichment** (`Ai::RepositoryAnalyzer`) — sends the deterministic result + file tree + README to Claude, which returns:
   - `app_description` — one-sentence description of what the app does
   - `additional_env_vars` — env vars the deterministic scan missed
   - `warnings` — additional deployment warnings
   - `confidence` — high / medium / low on the framework detection
   - `framework_notes` — corrections or clarifications to the detected framework

The merged result is cached on the project (`analysis_result` JSONB column) and surfaced in the UI before the user hits Deploy.

### Failure explanation

When a deployment fails, `ExplainErrorJob` fires asynchronously and calls `Ai::ErrorExplainer`, which sends the last 100 log lines and the error message to Claude. The response is a 2–4 sentence plain-English explanation of what went wrong and the most likely fix. It is stored on the deployment record and broadcast to the live log terminal if it's still open.

```
deploy failed
  └─ ExplainErrorJob (async, default queue)
       └─ Ai::ErrorExplainer → Anthropic API (Haiku)
            └─ explanation stored on deployment + broadcast via ActionCable
```

### Optional environment variable

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Enables AI enrichment and error explanation. If unset, both features are silently skipped. |

---

## Project Structure

```
app/
├── channels/
│   └── deployment_log_channel.rb     ActionCable — live log streaming
├── controllers/
│   ├── application_controller.rb     require_login, current_user
│   ├── auth_controller.rb            GitHub OAuth callback/logout
│   ├── dashboard_controller.rb
│   ├── deployments_controller.rb
│   ├── projects_controller.rb
│   ├── repositories_controller.rb
│   └── secrets_controller.rb
├── javascript/controllers/
│   ├── log_controller.js             Auto-scroll, line count, elapsed timer
│   ├── deploy_controller.js          Loading state on Deploy button
│   ├── clipboard_controller.js       Copy URL to clipboard
│   └── flash_controller.js           Auto-dismiss flash messages
├── jobs/
│   ├── deployment_job.rb             Entry point
│   ├── repository_analysis_job.rb    Pre-deploy repo analysis (deterministic + AI)
│   └── deployments/
│       ├── base_job.rb               Shared error handling, guard_status!
│       ├── prepare_job.rb            Clone + detect + Dockerfile
│       ├── build_image_job.rb        Cloud Build submit
│       ├── poll_build_status_job.rb  Polling with exponential backoff
│       ├── deploy_to_cloud_run_job.rb  gcloud run deploy
│       └── explain_error_job.rb      Async AI failure explanation
├── models/
│   ├── user.rb                       GitHub OAuth, encrypted token
│   ├── repository.rb                 Synced from GitHub API
│   ├── project.rb                    One project = one Cloud Run service
│   ├── deployment.rb                 State machine + Turbo broadcasts
│   ├── deployment_log.rb             Append-only log lines
│   └── secret.rb                     Encrypted env vars
├── services/
│   ├── framework_detector.rb         File-presence heuristics
│   ├── dockerfile_generator.rb       Templates per framework
│   ├── repository_analyzer.rb        Orchestrates deterministic analysis
│   ├── analysis/
│   │   ├── dependency_reader.rb      Reads deps from lockfiles
│   │   ├── env_var_detector.rb       Detects likely env vars from source
│   │   └── database_detector.rb      Detects DB type (postgres, mysql, etc.)
│   ├── ai/
│   │   ├── repository_analyzer.rb    AI enrichment of deterministic analysis
│   │   └── error_explainer.rb        Plain-English failure explanation
│   └── deployments/
│       └── cloud_run_deployer.rb     Legacy single-class deployer
└── views/
    ├── dashboard/index.html.erb      Landing page + project grid
    ├── deployments/
    │   ├── show.html.erb             Live log terminal
    │   ├── _outcome.html.erb         Service URL or error panel
    │   ├── _status_badge.html.erb    Turbo Stream replace target
    │   └── _log_line.html.erb        Single log line with timestamp
    ├── projects/
    │   ├── show.html.erb             Project detail + deployment list
    │   ├── _form.html.erb            Shared create/edit form
    │   └── _project.html.erb         Dashboard project card
    ├── repositories/index.html.erb   GitHub repo list + sync
    └── secrets/index.html.erb        Add/remove environment variables
```

---

## Database Schema

Six tables. All foreign keys enforced at the database level.

```
users
├── has_many repositories
└── has_many projects
      ├── has_many deployments
      │     └── has_many deployment_logs
      └── has_many secrets
```

| Table | Rows at 100k deploys/month |
|---|---|
| `users` | small |
| `repositories` | small |
| `projects` | small |
| `deployments` | 100,000/month |
| `deployment_logs` | ~20,000,000/month |
| `secrets` | small |

See [`docs/database_schema.md`](docs/database_schema.md) for full column reference.

---

## Hotwire / Real-Time Updates

Live updates require no custom WebSocket code. Everything runs through Turbo Streams:

| Event | Broadcast | Browser effect |
|---|---|---|
| `append_log` called | `broadcast_append_to "deployment_#{id}_logs"` | Log line appended to terminal |
| `transition_to!` called | `broadcast_replace_to "deployment_#{id}"` | Status badge updated |
| Terminal state reached | `broadcast_replace_to "deployment_#{id}"` (outcome) | URL or error panel appears |
| Terminal state reached | `broadcast_remove_to "deployment_#{id}_logs"` | Spinner removed |
| Deploy button clicked | `turbo_stream.prepend` | New deployment row appears in list |

The `log` Stimulus controller uses a `MutationObserver` to auto-scroll the terminal as Turbo appends lines, pausing if the user scrolls up manually.

---

## Deploying Anchor to Cloud Run

The default `Dockerfile` builds a production image using a multi-stage build with jemalloc. It does **not** include the `gcloud` CLI — you need to extend it for Sidekiq workers:

```dockerfile
# Add to Dockerfile before the final stage CMD
RUN apt-get update -qq && apt-get install -y apt-transport-https ca-certificates gnupg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
      https://packages.cloud.google.com/apt cloud-sdk main" \
      | tee /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    apt-get update -qq && apt-get install -y google-cloud-cli && \
    rm -rf /var/lib/apt/lists
```

Deploy two Cloud Run services from the same image:

```bash
# Web
gcloud run deploy anchor-web \
  --image=IMAGE_URL \
  --command="./bin/thrust,./bin/rails,server" \
  --set-env-vars=RAILS_MASTER_KEY=...,DATABASE_URL=...,REDIS_URL=...

# Worker (Sidekiq)
gcloud run deploy anchor-worker \
  --image=IMAGE_URL \
  --command="bundle,exec,sidekiq,-C,config/sidekiq.yml" \
  --set-env-vars=RAILS_MASTER_KEY=...,DATABASE_URL=...,REDIS_URL=...
```

Run migrations before first deploy:

```bash
gcloud run jobs create anchor-migrate \
  --image=IMAGE_URL \
  --command="bundle,exec,rails,db:migrate"

gcloud run jobs execute anchor-migrate
```

---

## Secrets

Two types of sensitive data are encrypted at rest using `attr_encrypted` (AES-256-CBC):

| Field | Model | Column in DB |
|---|---|---|
| GitHub OAuth token | `User` | `github_token` (ciphertext in single column) |
| Environment variable value | `Secret` | `encrypted_value` + `encrypted_value_iv` |

Both use the key at `credentials.dig(:encryption, :key)`. This key must be 32 bytes and must never be rotated without re-encrypting all records first.

---

## Scaling

The monolith handles 100k deployments/month with targeted changes at two trigger points:

**When `deployment_logs` hits 1M rows:**
- Add nightly GCS archival job
- Split Sidekiq into 4 queues by pipeline step
- Separate web and worker Cloud Run services

**When Sidekiq queue depth consistently >200:**
- Add PostgreSQL read replica
- Partition `deployment_logs` by month
- Scale Sidekiq workers horizontally

See [`docs/scaling.md`](docs/scaling.md) for the full analysis with load numbers.

---

## Documentation

| File | Contents |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | System diagram, component overview, auth flow, security model |
| [`docs/deployment_pipeline.md`](docs/deployment_pipeline.md) | Step-by-step pipeline, gcloud commands, error handling, GCP prereqs |
| [`docs/database_schema.md`](docs/database_schema.md) | Every table, column, index, and convention |
| [`docs/mvp_plan.md`](docs/mvp_plan.md) | 7-day build schedule, backlog, risk table, definition of done |
| [`docs/scaling.md`](docs/scaling.md) | Load model, failure modes, V1→V2→V3 changes, GCP quota management |

---

## Common Tasks

```bash
# Start development server
bin/dev

# Run database migrations
bundle exec rails db:migrate

# Open Rails console
bundle exec rails console

# Check Sidekiq queue depth
bundle exec rails runner "Sidekiq::Queue.all.each { |q| puts "#{q.name}: #{q.size}" }"

# Manually trigger a deployment (in console)
project = Project.find(1)
deployment = project.deployments.create!(status: "pending", triggered_by: "manual", branch: project.production_branch)
DeploymentJob.perform_later(deployment.id)

# Sync GitHub repositories for a user
user = User.find(1)
repos = user.github_client.repos(user.github_login, per_page: 100)
repos.each { |r| Repository.sync_from_github(user, r) }

# Check encryption is working
secret = Secret.create!(project: Project.first, key: "TEST_KEY", value: "hello")
puts secret.value          # => "hello"
puts secret.encrypted_value # => ciphertext
```

---

## Contributing

1. Branch from `main`
2. Make changes
3. Verify boot: `bundle exec rails runner "puts 'OK'"`
4. Verify routes: `bundle exec rails routes`
5. Open a pull request

There are no automated tests in V1. Add them before shipping V2.
