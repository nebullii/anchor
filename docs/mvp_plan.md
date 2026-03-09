# Anchor — MVP Plan

## Goal

Ship a working V1 of Anchor in 7 days. The product lets developers deploy GitHub repositories to Google Cloud Run through a web UI, with automatic framework detection, Docker build, and live deployment logs.

---

## What V1 Is

- A Rails monolith running on Cloud Run
- GitHub OAuth sign-in
- Connect any GitHub repository
- One-click deploy to Cloud Run
- Live deployment log terminal (Turbo Streams)
- Encrypted environment variable storage
- Basic project dashboard

## What V1 Is Not

- No auto-deploy on push (no GitHub webhooks)
- No custom domains
- No deploy preview environments
- No rollback UI (deploy again from history)
- No team/org support — single user per account
- No billing / usage metering
- No build caching

---

## 7-Day Schedule

### Day 1 — Rails Foundation

**Goal:** App boots, database migrates, GitHub OAuth works.

- [x] `rails new` with PostgreSQL, Propshaft, Hotwire, Tailwind
- [x] Add gems: sidekiq, omniauth-github, attr_encrypted, octokit, google-apis-*
- [x] Write 6 migrations and run them
- [x] Write models: User, Repository, Project, Deployment, DeploymentLog, Secret
- [x] GitHub OAuth flow: callback, session, logout
- [x] ApplicationController: `require_login`, `current_user`
- [x] Verify boot: `rails runner "puts 'OK'"`

**Done when:** `bin/dev` starts, visit `/`, click GitHub sign-in, land on dashboard.

---

### Day 2 — Repository Sync + Project CRUD

**Goal:** Users can connect a GitHub repo and create a project.

- [x] RepositoriesController: `index`, `sync`
- [x] `Repository.sync_from_github` — upsert from Octokit response
- [x] Repositories index view — list repos, sync button
- [x] ProjectsController: `index`, `show`, `new`, `create`, `edit`, `update`, `destroy`
- [x] Project form — name, repo picker, GCP project ID, region, branch
- [x] Project card partial — status badge, latest URL, deploy button
- [x] Dashboard index — project grid + recent deployments

**Done when:** User can sync repos from GitHub, create a project linked to a repo.

---

### Day 3 — Deployment Engine

**Goal:** Clicking Deploy triggers the full pipeline.

- [x] `Deployments::PrepareJob` — clone + detect + Dockerfile
- [x] `Deployments::BuildImageJob` — gcloud builds submit --async
- [x] `Deployments::PollBuildStatusJob` — poll with exponential backoff
- [x] `Deployments::DeployToCloudRunJob` — gcloud run deploy
- [x] `Deployments::BaseJob` — shared error handling, guard_status!, fail_deployment!
- [x] `FrameworkDetector` — file presence heuristics for 5 frameworks
- [x] `DockerfileGenerator` — templates for rails/node/python/static
- [x] DeploymentJob entry point — validates pending, chains PrepareJob
- [x] ProjectsController#deploy — creates Deployment, enqueues job

**Done when:** Deploy button creates a deployment record and pipeline jobs appear in Sidekiq.

---

### Day 4 — Live Deployment UI

**Goal:** Users can watch a deployment happen in real time.

- [x] `Deployment#append_log` — broadcast_append_to Turbo stream
- [x] `Deployment#transition_to!` — broadcast_replace_to status badge + outcome panel
- [x] DeploymentLogChannel — ActionCable channel with user auth
- [x] Deployments show view — log terminal with `data-controller="log"`
- [x] `_log_line.html.erb` partial — timestamp + level colouring
- [x] `_outcome.html.erb` partial — live URL or error panel
- [x] `_status_badge.html.erb` partial — Turbo replace target
- [x] Stimulus `log` controller — auto-scroll, line count, elapsed timer

**Done when:** Open a deployment page, click Deploy on another tab, watch logs appear live.

---

### Day 5 — Secrets + Project Polish

**Goal:** Users can set environment variables and see them injected at deploy time.

- [x] SecretsController: `index`, `create`, `destroy`
- [x] Secrets index view — add/remove form, masked value display
- [x] `Secret.to_cloud_run_env_string` — formats for `--set-env-vars`
- [x] `DeployToCloudRunJob` injects secrets from DB
- [x] Project show sidebar — stack info, GCP details, secrets count
- [x] Stimulus `clipboard` controller — copy service URL
- [x] Stimulus `deploy` controller — loading state on Deploy button
- [x] Stimulus `flash` controller — auto-dismiss flash messages

**Done when:** Add `DATABASE_URL=postgres://...` to a project, deploy, confirm it's set in Cloud Run.

---

### Day 6 — End-to-End Test + Bug Fixing

**Goal:** Complete deployment works for at least one real repo per framework.

Test matrix:

| Framework | Repo type | Expected outcome |
|---|---|---|
| Rails | App with Gemfile + Puma | Deploys, serves requests |
| Node | Express app with package.json | Deploys, serves requests |
| Python | Flask app with requirements.txt | Deploys, serves requests |
| Static | HTML/CSS in root | Deploys, serves static files |
| Docker | Repo with existing Dockerfile | Uses existing file, deploys |

Common failure modes to check:
- Build timeout (increase `--timeout` in BuildImageJob)
- Missing Artifact Registry repository (add to onboarding docs)
- Cloud Run service account missing IAM roles
- Port mismatch (app listening on different port than detected)

---

### Day 7 — Production Deploy + Hardening

**Goal:** Anchor itself runs on Cloud Run.

- [ ] Review `Dockerfile` — ensure gcloud CLI is installed
- [ ] Set all required environment variables in Cloud Run
- [ ] Run `rails db:migrate` against production PostgreSQL
- [ ] Verify Redis is reachable from Cloud Run (use Memorystore or Redis Cloud)
- [ ] Set `RAILS_LOG_TO_STDOUT=true`
- [ ] Set `RAILS_SERVE_STATIC_FILES=true`
- [ ] Configure `SECRET_KEY_BASE` or `RAILS_MASTER_KEY`
- [ ] Test OAuth callback URL matches production domain
- [ ] Smoke test full deploy flow on production

---

## Backlog (Post-V1)

These are deliberately excluded from V1 to keep scope manageable.

### High Value — V2

| Feature | Effort | Notes |
|---|---|---|
| GitHub webhook auto-deploy | Medium | Push to branch → trigger deploy |
| Deploy from specific commit | Small | SHA picker on deploy form |
| Rollback to previous deployment | Small | Re-deploy from `image_url` |
| Build log streaming from Cloud Build API | Medium | Replace polling with API streaming |
| Custom Cloud Run settings per project | Small | Memory, CPU, min/max instances |
| Delete project → destroy Cloud Run service | Small | Cleanup GCP resources |

### Medium Value — V3

| Feature | Effort | Notes |
|---|---|---|
| Preview deployments per branch | Large | Separate Cloud Run service per branch |
| Custom domains | Medium | Cloud Run domain mapping |
| Deploy notifications (email/Slack) | Small | ActionMailer + webhook |
| Sidekiq Web UI with auth | Small | Mount behind admin check |
| GCP project selection from dropdown | Medium | List projects via Resource Manager API |

### Lower Priority

| Feature | Effort | Notes |
|---|---|---|
| Team/org support | Large | Multi-user projects |
| Usage dashboard (build minutes, requests) | Large | Cloud Monitoring API |
| GitHub App instead of OAuth | Medium | Better token scoping, webhook support |
| Build cache | Large | Requires persistent layer storage |
| Multiple GCP accounts per user | Medium | Per-project service account |

---

## Environment Variables Reference

Required in all environments:

| Variable | Example | Source |
|---|---|---|
| `DATABASE_URL` | `postgres://user:pass@host/db` | Managed PostgreSQL |
| `REDIS_URL` | `redis://host:6379/0` | Redis instance |
| `RAILS_MASTER_KEY` | 32-char hex | `config/master.key` |
| `GOOGLE_APPLICATION_CREDENTIALS` | `/secrets/sa.json` | GCP service account JSON |

Stored in Rails credentials (`config/credentials.yml.enc`):

```yaml
github:
  client_id:     "..."
  client_secret: "..."

encryption:
  key: "32-byte-string"   # SecureRandom.hex(16)
```

Production-only:

| Variable | Value |
|---|---|
| `RAILS_ENV` | `production` |
| `RAILS_LOG_TO_STDOUT` | `true` |
| `RAILS_SERVE_STATIC_FILES` | `true` |

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cloud Build quota limits | Medium | Default quota is 120 build-minutes/day on free tier — upgrade or request increase |
| gcloud CLI auth in Cloud Run | Medium | Use Workload Identity or mount service account JSON as a secret volume |
| Long build times blocking Sidekiq thread | Low | `--async` flag means thread is released immediately after submit |
| GitHub rate limits on repo sync | Low | Sync is manual in V1; cache results with `last_synced_at` |
| Dockerfile generation incorrect for unusual apps | Medium | Fall back to `docker` framework if user provides their own Dockerfile |
| Redis unavailable kills all background jobs | Low | Use Cloud Memorystore (managed Redis) in production; add health check |

---

## Definition of Done (V1)

- [ ] User can sign in with GitHub
- [ ] User can sync their repositories
- [ ] User can create a project linked to a repo
- [ ] User can add environment variables (encrypted)
- [ ] User can click Deploy and see live logs stream to the browser
- [ ] Successful deployment shows a live Cloud Run URL
- [ ] Failed deployment shows an error message with relevant log lines
- [ ] The Anchor platform itself is deployed to Cloud Run
- [ ] All secrets and credentials are stored securely (never in source control)
