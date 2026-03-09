# Anchor — System Architecture

## Overview

Anchor is a Rails 8 monolith that provides a self-hosted deployment platform for Google Cloud Run. Users connect GitHub repositories and deploy them with one click. The platform handles framework detection, Docker image builds, and Cloud Run deployments entirely through background jobs.

---

## High-Level Diagram

```
Browser (Hotwire)
  │
  │  HTTP + WebSocket (ActionCable)
  ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Rails 8 Monolith                         │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────────┐ │
│  │  Controllers │   │   Services   │   │   Sidekiq Jobs      │ │
│  │  + Hotwire   │──▶│   (POROs)    │◀──│   (5-step pipeline) │ │
│  └──────────────┘   └──────────────┘   └─────────────────────┘ │
│           │                                       │             │
│  ┌────────▼──────────────────────────────────┐    │             │
│  │            PostgreSQL                      │◀───┘             │
│  │  users · repositories · projects           │                 │
│  │  deployments · deployment_logs · secrets   │                 │
│  └───────────────────────────────────────────┘                 │
│                                                                 │
│  ┌──────────────────────┐  ┌──────────────────────────────────┐ │
│  │  Turbo Streams       │  │  Redis                           │ │
│  │  (live log/status)   │  │  Sidekiq queue + ActionCable     │ │
│  └──────────────────────┘  └──────────────────────────────────┘ │
└──────────────┬──────────────────────┬───────────────────────────┘
               │                      │
   ┌───────────▼──────────┐  ┌────────▼───────────────────────────┐
   │    GitHub API         │  │    Google Cloud APIs               │
   │  OAuth + Octokit      │  │  Cloud Build · Cloud Run           │
   │  repo clone (git)     │  │  Artifact Registry                 │
   └───────────────────────┘  └────────────────────────────────────┘
```

---

## Components

### Rails Application

**Controllers** handle HTTP requests, enforce authentication, and return HTML or Turbo Stream responses. They are thin — business logic lives in service objects or jobs.

**Service Objects** (`app/services/`) are plain Ruby classes with a single public method (`#call`). They encapsulate discrete operations: framework detection, Dockerfile generation, repo cloning.

**Background Jobs** (`app/jobs/`) run the deployment pipeline asynchronously via Sidekiq. Each job handles one pipeline step and chains to the next on success.

**Models** hold validations, associations, and domain behaviour. `Deployment` owns the state machine and all Turbo Stream broadcasts.

### PostgreSQL

Single primary database. No read replicas or multi-database setup in V1.

Connection pooled via Puma threads (`RAILS_MAX_THREADS`, default 5). Sidekiq workers use a separate pool sized to `concurrency` in `config/sidekiq.yml`.

### Redis

Two consumers:
- **Sidekiq** — job queues (`deployments` at priority 3, `default` at priority 1)
- **ActionCable** — pub/sub for Turbo Stream broadcasts

Configured via `REDIS_URL` environment variable.

### Hotwire (Turbo + Stimulus)

Real-time UI updates without custom WebSocket code:

- **Turbo Streams** — server broadcasts HTML fragments that the browser applies as DOM patches (append, replace, remove). Used for live log lines, status badges, and outcome panels.
- **Turbo Frames** — scopes navigation and form responses to a sub-region of the page. Used for the deployment list on the project show page.
- **Stimulus** — lightweight JS controllers for behaviour that can't be expressed in HTML alone: auto-scroll (`log`), clipboard copy, deploy button loading state, flash auto-dismiss.

### Google Cloud

| Service | Usage |
|---|---|
| **Cloud Build** | Builds Docker images from source. Source uploaded to GCS automatically by `gcloud builds submit`. |
| **Artifact Registry** | Stores built images. Image path: `REGION-docker.pkg.dev/GCP_PROJECT/cloudlaunch/SERVICE:DEPLOYMENT_ID` |
| **Cloud Run** | Runs containers. One Cloud Run service per Anchor project. |

All GCP interactions use the `gcloud` CLI in V1. The CLI must be available on the server running Sidekiq workers.

---

## Authentication

GitHub OAuth via OmniAuth. Flow:

```
User clicks "Sign in with GitHub"
  → POST /auth/github (CSRF-protected)
  → GitHub OAuth consent screen
  → GET /auth/github/callback
  → AuthController#callback
  → User.from_omniauth(auth)  — upsert user record
  → session[:user_id] = user.id
  → redirect to dashboard
```

GitHub tokens are stored encrypted at rest using `attr_encrypted` with a key from Rails credentials (`credentials.dig(:encryption, :key)`). The same key encrypts `Secret#value`.

ActionCable connections authenticate by reading `session[:user_id]` from the signed cookie.

---

## Security

| Concern | Mitigation |
|---|---|
| GitHub tokens | `attr_encrypted` — AES-256-CBC, key in Rails credentials, never in DB plaintext |
| User secrets | Same encryption as tokens |
| Authenticated clone URLs | Token embedded in URL; never logged (redacted in job output) |
| GCP credentials | Application Default Credentials via `GOOGLE_APPLICATION_CREDENTIALS` env var |
| Authorization | All queries scoped to `current_user` — no global model queries in controllers |
| CSRF | OmniAuth `rails_csrf_protection` + Rails `authenticity_token` on all forms |
| Secret env var keys | Validated against `UPPER_SNAKE_CASE` regex; reserved keys blocked |

---

## Deployment of Anchor Itself

Anchor is containerized and deployed to Cloud Run using the provided `Dockerfile`. The `gcloud` CLI is included in the image so workers can trigger Cloud Build and Cloud Run deploys.

Environment variables required at runtime:

```
DATABASE_URL              postgres://...
REDIS_URL                 redis://...
RAILS_MASTER_KEY          (from config/master.key)
GOOGLE_APPLICATION_CREDENTIALS  /path/to/service-account.json
SECRET_KEY_BASE           (for cookie signing — auto-derived from master key in Rails 8)
```

---

## Directory Structure

```
app/
├── channels/           ActionCable — DeploymentLogChannel
├── controllers/        HTTP layer — thin, auth-enforced
├── helpers/            ApplicationHelper — status_badge_class, framework_icon, etc.
├── javascript/
│   └── controllers/    Stimulus — log, deploy, clipboard, flash
├── jobs/
│   ├── deployment_job.rb           Entry point
│   └── deployments/
│       ├── base_job.rb             Shared error handling
│       ├── prepare_job.rb          Clone + detect + Dockerfile
│       ├── build_image_job.rb      Cloud Build submit
│       ├── poll_build_status_job.rb  Async polling with backoff
│       └── deploy_to_cloud_run_job.rb  gcloud run deploy
├── models/             AR models — validations, associations, broadcasts
├── services/
│   ├── framework_detector.rb
│   ├── dockerfile_generator.rb
│   └── deployments/
│       └── cloud_run_deployer.rb   (legacy single-class deployer — superseded by jobs)
└── views/
    ├── deployments/    show (live log terminal), index, partials
    ├── projects/       show, new, edit, _project card
    ├── repositories/   index + sync
    ├── secrets/        index (add/remove env vars)
    └── shared/         _notice partial

config/
├── credentials.yml.enc   GitHub OAuth keys + encryption key
├── sidekiq.yml           Queue config
└── initializers/
    ├── omniauth.rb
    └── sidekiq.rb

db/migrate/             6 migrations — users through secrets
docs/                   Architecture, pipeline, schema, MVP plan
```
