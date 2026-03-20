<p align="center">
  <img src="docs/screenshots/dashboard.png" width="720" alt="Anchor Dashboard" />
</p>

<h1 align="center">Anchor</h1>

<p align="center">
  <strong>Autonomous deployment platform that takes any GitHub repo from code to a live URL in one click.</strong>
</p>

<p align="center">
  <a href="https://github.com/nebullii/anchor/actions/workflows/ci.yml"><img src="https://github.com/nebullii/anchor/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Ruby-3.4.4-CC342D?logo=ruby&logoColor=white" alt="Ruby 3.4.4">
  <img src="https://img.shields.io/badge/Rails-8.1-D30001?logo=rubyonrails&logoColor=white" alt="Rails 8.1">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://anchor-prod-cuk7hgt2pq-uc.a.run.app"><strong>Live Demo</strong></a>
</p>

---

Anchor connects to your GitHub account, detects your framework, generates a production Dockerfile, builds a container image, deploys it to the cloud, and streams every log line to your browser in real time. When something breaks, an AI agent explains the failure in plain English.

No Kubernetes. No YAML. No ops team. Your infrastructure, your cloud bill — Anchor is just the control plane.

## Key Features

- **Framework auto-detection** — Rails, Django, FastAPI, Next.js, Go, Elixir, and more
- **Dockerfile generation** — production-ready, multi-stage builds generated per framework
- **Encrypted secrets management** — AES-256-CBC at rest, injected at deploy time
- **Live log streaming** — Turbo Streams over ActionCable, real-time in-browser terminal
- **AI error diagnosis** — Claude analyzes failures and explains fixes in plain English
- **GitHub webhook deploys** — auto-deploy on push with HMAC-SHA256 verification
- **Deploy quotas & rate limiting** — Rack::Attack + per-user quota enforcement

## Cloud Providers

| Provider | Status |
|---|---|
| Google Cloud Run | **Live** |
| AWS (ECS / App Runner) | Planned |
| Azure Container Apps | Planned |
| Fly.io | Planned |

The architecture is provider-agnostic — a `ProviderAdapter` interface allows adding new clouds without touching the deployment pipeline.

## How It Works

```
GitHub repo → Clone → Framework detection → Dockerfile generation
                                                    ↓
                                   Cloud Build → Container image → Artifact Registry
                                                                         ↓
                                                    Cloud Run deploy → Health check → Live URL
                                                                         ↓
                                                           (on failure) AI error explanation
```

1. **Sign in** with GitHub OAuth
2. **Select a repo** — Anchor syncs your repositories via the GitHub API
3. **Connect your cloud** — Google OAuth or service account key
4. **Add secrets** — encrypted, scoped per project
5. **Deploy** — one click, watch logs stream live
6. **Get a URL** — publicly accessible, SSL-terminated

## Architecture

### Deployment Pipeline

Five Sidekiq jobs execute in sequence. Each hands off to the next on success. Any failure triggers the AI error explainer.

```
DeploymentJob
  └─ PrepareJob              # clone, detect framework, generate Dockerfile
       └─ BuildImageJob      # gcloud builds submit --async
            └─ PollBuildStatusJob      # exponential backoff polling
                 └─ DeployToCloudRunJob  # deploy + health check
                      └─ ExplainErrorJob   # AI diagnosis (on failure)
```

### Status Machine

```
queued → analyzing → building → deploying → health_check → running
                                                         → failed → AI explanation
                                                         → cancelled
```

### Real-Time Streaming

Every deployment broadcasts two Turbo Stream channels:

| Channel | Purpose |
|---|---|
| `deployment_<id>` | Status transitions, pipeline progress, outcome panel |
| `deployment_<id>_logs` | Individual log lines appended to an in-browser terminal |

### Data Model

| Model | Responsibility |
|---|---|
| `User` | Encrypted OAuth tokens, GCP credentials, deployment quotas |
| `Repository` | GitHub repos synced via Octokit |
| `Project` | Service config, framework detection, analysis results |
| `Deployment` | Full lifecycle — status, logs, plan, error category, AI explanation |
| `DeploymentLog` | Append-only log stream, broadcast via Turbo |
| `DeploymentEvent` | Immutable audit trail of every status transition |
| `Secret` | AES-256-CBC encrypted env vars, scoped per project |

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Ruby on Rails 8.1 |
| Language | Ruby 3.4.4 |
| Database | PostgreSQL 16 |
| Background Jobs | Sidekiq 8 + Redis 7 |
| Frontend | Hotwire (Turbo Streams + Stimulus) + Tailwind CSS v4 |
| Real-Time | ActionCable over Redis |
| Auth | OmniAuth (GitHub OAuth2 + Google OAuth2) |
| Encryption | attr_encrypted (AES-256-CBC) |
| AI | Anthropic Claude (error explanation + repo analysis) |
| Rate Limiting | Rack::Attack |
| Infrastructure | Docker, Google Cloud Build, Artifact Registry, Cloud Run |
| CI/CD | GitHub Actions (test + security scan + build + migrate + deploy) |

## Supported Frameworks

Rails | Node.js | Next.js | Bun | Python | FastAPI | Flask | Django | Go | Elixir | Static HTML | Docker

## Security

- All OAuth tokens and secrets encrypted at rest (AES-256-CBC)
- Encryption key validated at boot — app refuses to start without it
- Google OAuth tokens refreshed automatically with advisory locking
- GitHub webhooks verified with HMAC-SHA256
- Temporary GCP credential files written to `Tempfile`, deleted immediately after use
- CSRF protection on all non-webhook endpoints
- Rate limiting: 300 req/5 min per IP, 20 deploys/hour per user
- Clone tokens redacted from all logs
- Env vars passed via `--env-vars-file` (YAML) to prevent injection

## Screenshots

<p align="center">
  <img src="docs/screenshots/dashboard.png" width="720" alt="Dashboard — deployment overview with live status" />
</p>

<p align="center">
  <img src="docs/screenshots/repositories.png" width="720" alt="Repository selection — synced from GitHub" />
</p>

## Getting Started

### Prerequisites

- Ruby 3.4.4 (`rbenv` or `mise`)
- PostgreSQL 16+
- Redis 7+
- [`gcloud` CLI](https://cloud.google.com/sdk/docs/install)
- [GitHub OAuth App](https://github.com/settings/applications/new)
- A Google Cloud project with billing enabled

### Setup

```bash
git clone https://github.com/nebullii/anchor.git && cd anchor
bundle install
```

Configure credentials:

```bash
EDITOR="nano" bundle exec rails credentials:edit
```

```yaml
github:
  client_id: "YOUR_GITHUB_CLIENT_ID"
  client_secret: "YOUR_GITHUB_CLIENT_SECRET"

google:
  client_id: "YOUR_GOOGLE_CLIENT_ID"
  client_secret: "YOUR_GOOGLE_CLIENT_SECRET"

encryption:
  key: "your-32-byte-hex-key"   # ruby -e "require 'securerandom'; puts SecureRandom.hex(16)"

anthropic:
  api_key: "sk-ant-..."          # optional — AI features degrade gracefully
```

```bash
bundle exec rails db:create db:migrate
bin/dev    # http://localhost:3000
```

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `RAILS_MASTER_KEY` | Yes | Contents of `config/master.key` |
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `REDIS_URL` | Yes | Redis connection string (Sidekiq + ActionCable + Rack::Attack) |
| `ENCRYPTION_KEY` | Yes | 32-byte AES-256 key — app will not boot without it |
| `GITHUB_CLIENT_ID` | Yes | GitHub OAuth app client ID |
| `GITHUB_CLIENT_SECRET` | Yes | GitHub OAuth app secret |
| `GOOGLE_CLIENT_ID` | Yes | Google OAuth client ID (for GCP integration) |
| `GOOGLE_CLIENT_SECRET` | Yes | Google OAuth client secret |
| `ANTHROPIC_API_KEY` | No | Enables AI error explanation + repo analysis |
| `GITHUB_WEBHOOK_SECRET` | No | HMAC secret for webhook verification |

## Running Tests

```bash
bundle exec rspec                # full suite
bundle exec rspec spec/models
bundle exec rspec spec/jobs
bundle exec rspec spec/services
```

Tests use WebMock — no real GitHub or GCP calls are made.

## Contributing

1. Fork and create a branch: `git checkout -b feature/my-feature`
2. Make changes with tests
3. Ensure the suite passes: `bundle exec rspec`
4. Open a pull request against `main`

## License

[MIT](LICENSE)
