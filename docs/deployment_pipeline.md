# Anchor — Deployment Pipeline

## Overview

Every deployment runs through a 5-job Sidekiq pipeline. Each job handles one step, transitions the `Deployment` record's status, and chains the next job on success. Failures at any step mark the deployment as `failed` and surface the error in the UI via Turbo Streams.

---

## Pipeline Diagram

```
User clicks "Deploy"
  │
  ▼
ProjectsController#deploy
  → Deployment.create!(status: "pending")
  → DeploymentJob.perform_later(deployment_id)

┌─────────────────────────────────────────────────────────────────────┐
│  Sidekiq — :deployments queue                                        │
│                                                                     │
│  1. DeploymentJob            status: pending                        │
│     └── validates pending, chains PrepareJob                        │
│                                                                     │
│  2. Deployments::PrepareJob  status: cloning → detecting            │
│     ├── git clone --depth=1 (token redacted from logs)              │
│     ├── FrameworkDetector → saves FrameworkDetection                │
│     ├── DockerfileGenerator → skips if Dockerfile exists            │
│     └── chains BuildImageJob(repo_path)                             │
│                                                                     │
│  3. Deployments::BuildImageJob  status: building                    │
│     ├── gcloud builds submit --async → returns build_id             │
│     ├── saves image_url + cloud_build_id on Deployment              │
│     ├── deletes /tmp repo (source uploaded to GCS)                  │
│     └── chains PollBuildStatusJob(build_id, attempt: 1)             │
│                                                                     │
│  4. Deployments::PollBuildStatusJob  status: building (polling)     │
│     ├── gcloud builds describe → fetch status                       │
│     ├── if WORKING/QUEUED: re-enqueue after backoff delay           │
│     │     attempts 1–3  → 15s                                       │
│     │     attempts 4–8  → 30s                                       │
│     │     attempts 9–40 → 60s  (max ~28 min total)                  │
│     ├── if SUCCESS: chains DeployToCloudRunJob                      │
│     └── if FAILURE/TIMEOUT/CANCELLED: fails deployment              │
│                                                                     │
│  5. Deployments::DeployToCloudRunJob  status: deploying → success   │
│     ├── gcloud run deploy --format=json                             │
│     ├── injects secrets as --set-env-vars                           │
│     ├── parses service URL from JSON output                         │
│     ├── updates Deployment.service_url + Project.latest_url         │
│     └── transition_to!("success") → broadcasts Turbo Stream        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Status Transitions

```
pending → cloning → detecting → building → deploying → success
                                                      → failed
                                                      → cancelled
```

Every `transition_to!` call:
1. Updates `deployments.status` in the DB
2. Sets `started_at` when entering `cloning`
3. Sets `finished_at` when entering `success`, `failed`, or `cancelled`
4. Calls `sync_project_status!` — updates `projects.status` and `projects.latest_url`
5. Broadcasts two Turbo Stream `replace` actions:
   - Status badge on the project show page
   - Status badge on the deployment show page
6. On terminal states: broadcasts `replace` for the outcome panel and `remove` for the log spinner

---

## Step Detail

### Step 1 — DeploymentJob (entry point)

- Finds the deployment by ID
- Guards against duplicate execution — exits silently if status is not `pending`
- Enqueues `PrepareJob`
- No retry (`sidekiq_options retry: 0`)

### Step 2 — PrepareJob

**Clone**

```bash
git clone --depth=1 --branch BRANCH AUTHENTICATED_URL /tmp/cloudlaunch/PROJECT_ID/DEPLOYMENT_ID
```

- Shallow clone (`--depth=1`) for speed
- Authenticated URL contains the GitHub token — never appears in deployment logs (replaced with `[REDACTED]`)
- Saves `commit_sha`, `commit_message`, `commit_author`, `branch` to the Deployment record

**Framework Detection** (`FrameworkDetector`)

Detection is based on file presence, checked in priority order:

| Priority | Framework | Runtime | Signal file |
|---|---|---|---|
| 1 | docker | custom | `Dockerfile` |
| 2 | rails | ruby3.2 | `Gemfile` containing "rails" |
| 3 | node | node20 | `package.json` |
| 4 | python | python3.11 | `requirements.txt` or `pyproject.toml` |
| 5 | static | nginx | `index.html` |

Additional metadata extracted per framework:
- **rails** — Ruby version from `.ruby-version` or `Gemfile.lock`
- **node** — Node version from `.nvmrc`, start/build scripts from `package.json`
- **python** — Entry point detection (`app.py`, `manage.py`, `main.py`, etc.)

Result saved to `framework_detections` table and denormalized onto the `projects` record.

**Dockerfile Generation** (`DockerfileGenerator`)

Skipped if the repo already contains a `Dockerfile`. Otherwise generates one from a template:

| Framework | Base image | CMD |
|---|---|---|
| rails | `ruby:VERSION-slim` | `bundle exec puma` |
| node | `node:VERSION-alpine` | `npm start` or `node index.js` |
| python | `python:3.11-slim` | `python app.py` or `gunicorn` |
| static | `nginx:alpine` | `nginx -g daemon off` |

### Step 3 — BuildImageJob

Submits the source directory to Cloud Build using the `--async` flag, which returns immediately with a build ID rather than blocking the Sidekiq thread for the full build duration.

```bash
gcloud builds submit \
  --project=GCP_PROJECT_ID \
  --tag=REGION-docker.pkg.dev/GCP_PROJECT/cloudlaunch/SERVICE:DEPLOYMENT_ID \
  --timeout=30m \
  --async \
  --format=value(id) \
  /tmp/cloudlaunch/PROJECT_ID/DEPLOYMENT_ID
```

Cloud Build:
1. Uploads source to a temporary GCS bucket
2. Runs `docker build -t IMAGE_URL .`
3. Pushes the image to Artifact Registry

The local `/tmp` directory is deleted in an `ensure` block after the source is uploaded.

### Step 4 — PollBuildStatusJob

Polls Cloud Build via:

```bash
gcloud builds describe BUILD_ID \
  --project=GCP_PROJECT_ID \
  --format=value(status)
```

Possible statuses returned by Cloud Build:

| Status | Action |
|---|---|
| `QUEUED`, `WORKING` | Re-enqueue with backoff |
| `SUCCESS` | Save log URL, chain `DeployToCloudRunJob` |
| `FAILURE` | Fetch `failureInfo.detail`, fail deployment |
| `TIMEOUT` | Fail deployment |
| `CANCELLED` | Fail deployment |
| `INTERNAL_ERROR` | Fail deployment |
| `EXPIRED` | Fail deployment |

Max 40 poll attempts (~28 minutes total) before forcing a timeout failure.

### Step 5 — DeployToCloudRunJob

```bash
gcloud run deploy SERVICE_NAME \
  --project=GCP_PROJECT_ID \
  --region=REGION \
  --image=IMAGE_URL \
  --platform=managed \
  --allow-unauthenticated \
  --port=PORT \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --set-env-vars=KEY1=val1,KEY2=val2 \
  --format=json
```

Cloud Run settings (V1 defaults — configurable per project in V2):

| Setting | Value | Notes |
|---|---|---|
| Memory | 512Mi | Suitable for most web apps |
| CPU | 1 | Scales to 0 when idle |
| Min instances | 0 | Cold starts possible — set to 1 for latency-sensitive apps |
| Max instances | 10 | Adjust based on expected traffic |
| Auth | `--allow-unauthenticated` | Public by default |

The service URL is extracted from the JSON response (`status.url`) with a regex fallback for `*.run.app` URLs.

---

## Error Handling

All deployment jobs inherit from `Deployments::BaseJob` which provides:

```ruby
def with_deployment(deployment_id)
  deployment = Deployment.find(deployment_id)
  yield deployment
rescue Deployments::DeploymentError => e
  fail_deployment!(deployment, e.message)
rescue ActiveRecord::RecordNotFound
  # log and discard — deployment was deleted
rescue => e
  fail_deployment!(deployment, "#{e.class}: #{e.message}")
  raise  # re-raise so Sidekiq marks job as failed in its UI
end
```

`fail_deployment!` does three things:
1. Saves `error_message` on the Deployment record
2. Appends a red log line visible in the UI
3. Calls `transition_to!("failed")` which triggers all Turbo broadcasts

`DeploymentError` is a named exception for known pipeline failures (non-zero exit codes, missing build IDs, unparseable URLs). Unexpected `StandardError` subclasses are re-raised so Sidekiq's dead job queue captures them for debugging.

---

## Re-running a Failed Deployment

V1 does not auto-retry failed deployments. The user clicks "Deploy" again from the project page, which creates a new `Deployment` record and starts the pipeline from step 1. Failed deployments are preserved in history with their logs intact.

---

## Live Log Streaming

Log lines flow from the Sidekiq worker to the browser via Turbo Streams:

```
Job calls deployment.append_log(message)
  → DeploymentLog.create!
  → Turbo::StreamsChannel.broadcast_append_to(
       "deployment_#{id}_logs",
       target:  "deployment_logs",
       partial: "deployments/log_line",
       locals:  { log: log }
     )
  → ActionCable pushes rendered HTML to subscribed browsers
  → Browser Turbo client appends the <div> to #deployment_logs
  → Stimulus log controller MutationObserver fires
  → Auto-scrolls to bottom (unless user scrolled up)
  → Line count incremented
```

No custom JavaScript is needed in the view — `turbo_stream_from "deployment_#{id}_logs"` handles the ActionCable subscription and DOM patching automatically.

---

## GCP Prerequisites

Before deploying a project, the following must be set up in the target GCP project:

1. **Artifact Registry** — create a Docker repository named `cloudlaunch`:
   ```bash
   gcloud artifacts repositories create cloudlaunch \
     --repository-format=docker \
     --location=REGION \
     --project=GCP_PROJECT_ID
   ```

2. **Cloud Build API** — enable:
   ```bash
   gcloud services enable cloudbuild.googleapis.com --project=GCP_PROJECT_ID
   ```

3. **Cloud Run API** — enable:
   ```bash
   gcloud services enable run.googleapis.com --project=GCP_PROJECT_ID
   ```

4. **IAM** — the service account running Anchor needs these roles:
   - `roles/cloudbuild.builds.editor`
   - `roles/run.admin`
   - `roles/artifactregistry.writer`
   - `roles/storage.admin` (for GCS source uploads)
   - `roles/iam.serviceAccountUser`
