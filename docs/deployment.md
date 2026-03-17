# Production Deployment

Anchor deploys to Google Cloud Run via GitHub Actions. The pipeline runs automatically on every push to `main`:

```
push to main
  └─ run tests (RSpec)
  └─ security scan (Brakeman + bundle-audit)
       └─ build Docker image → push to Artifact Registry
            └─ run database migrations (Cloud Run Job)
                 └─ deploy web service (Cloud Run)
                      └─ deploy Sidekiq worker (Cloud Run)
```

Everything is defined in `.github/workflows/deploy-prod.yml`. No manual steps are required after initial setup.

---

## Architecture

| Component | Cloud Run service | Min instances | Notes |
|---|---|---|---|
| Web (Puma + Rails) | `anchor-prod` | 0 (scale to zero) | Raise to 1 to eliminate cold starts |
| Background jobs | `anchor-worker` | 1 (always on) | CPU always allocated; must stay warm to poll Redis |
| Migrations | `anchor-migrate` (Job) | — | Created and executed on every deploy, then idle |

---

## One-time GCP setup

These steps run once. After setup, all subsequent deploys are fully automated.

### 1. Create a GCP project

```bash
gcloud projects create YOUR_PROJECT_ID --name="Anchor Production"
gcloud config set project YOUR_PROJECT_ID
gcloud billing accounts list                          # find your billing account ID
gcloud billing projects link YOUR_PROJECT_ID \
  --billing-account=YOUR_BILLING_ACCOUNT_ID
```

### 2. Enable required APIs

```bash
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com
```

### 3. Create the Artifact Registry repository

```bash
gcloud artifacts repositories create anchor \
  --repository-format=docker \
  --location=us-central1 \
  --description="Anchor production container images"
```

Images will be pushed to:
```
us-central1-docker.pkg.dev/YOUR_PROJECT_ID/anchor/app
```

### 4. Create a service account for GitHub Actions

```bash
gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions deploy"

SA="github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com"
```

Grant the minimum required roles:

```bash
# Push images to Artifact Registry
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/artifactregistry.writer"

# Deploy and manage Cloud Run services
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/run.admin"

# Create and execute Cloud Run Jobs (migrations)
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/run.jobs.admin"

# Required to deploy Cloud Run services as a service account
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/iam.serviceAccountUser"

# Connect to Cloud SQL from Cloud Run
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/cloudsql.client"
```

Export the key for GitHub Secrets:

```bash
gcloud iam service-accounts keys create gcp-sa-key.json \
  --iam-account=$SA

cat gcp-sa-key.json   # copy this entire JSON → GCP_SA_KEY secret
rm gcp-sa-key.json    # delete immediately after copying
```

### 5. Create the Cloud SQL database

```bash
# Create instance (db-f1-micro is the smallest tier — upgrade for production load)
gcloud sql instances create anchor-db \
  --database-version=POSTGRES_15 \
  --tier=db-f1-micro \
  --region=us-central1 \
  --no-assign-ip \
  --network=default

# Create database and user
gcloud sql databases create anchor_production --instance=anchor-db
gcloud sql users create anchor \
  --instance=anchor-db \
  --password=YOUR_STRONG_PASSWORD
```

Construct the `DATABASE_URL`:

```
postgresql://anchor:YOUR_STRONG_PASSWORD@localhost/anchor_production?host=/cloudsql/YOUR_PROJECT_ID:us-central1:anchor-db
```

The `/cloudsql/...` socket path is how Cloud Run connects to Cloud SQL without a public IP.
Add `--add-cloudsql-instances=YOUR_PROJECT_ID:us-central1:anchor-db` to the gcloud run deploy
commands in `deploy-prod.yml` if using Cloud SQL Auth Proxy (see note in [deploy-prod.yml]).

### 6. Provision a Redis instance

Cloud Run does not include Redis. Options:

**Redis Cloud (recommended for most teams):**
Create a free database at [redis.com](https://redis.com) or [Upstash](https://upstash.com).
Copy the `redis://...` connection URL → `REDIS_URL_PROD` secret.

**Cloud Memorystore (GCP-native, VPC required):**
```bash
gcloud redis instances create anchor-redis \
  --size=1 \
  --region=us-central1 \
  --redis-version=redis_7_0
```
Requires VPC connector to connect from Cloud Run.

### 7. Create GitHub OAuth app for production

In GitHub → Settings → Developer Settings → OAuth Apps → New OAuth App:

| Field | Value |
|---|---|
| Homepage URL | `https://your-cloud-run-url.run.app` |
| Authorization callback URL | `https://your-cloud-run-url.run.app/auth/github/callback` |

Update the URL after the first deploy.

---

## GitHub Secrets configuration

Go to **GitHub → your repo → Settings → Secrets and variables → Actions → New repository secret**.

Create every secret below. Missing secrets will cause the deploy to fail silently or at runtime.

| Secret | Description | Example / source |
|---|---|---|
| `GCP_PROJECT_ID` | GCP project ID | `my-anchor-prod` |
| `GCP_REGION` | Deployment region | `us-central1` |
| `GCP_SA_KEY` | Full JSON of the service account key | output of step 4 above |
| `DATABASE_URL_PROD` | PostgreSQL connection string | `postgresql://anchor:pass@localhost/anchor_production?host=/cloudsql/...` |
| `REDIS_URL_PROD` | Redis connection string | `redis://...` |
| `RAILS_MASTER_KEY` | Contents of `config/master.key` | 32-char hex string |
| `SECRET_KEY_BASE` | Rails secret key base | `bundle exec rails secret` |
| `ENCRYPTION_KEY` | 32-byte AES-256 key for attr_encrypted | `ruby -e "puts SecureRandom.hex(16)"` |
| `GH_CLIENT_ID` | GitHub OAuth app client ID | from step 7 above |
| `GH_CLIENT_SECRET` | GitHub OAuth app client secret | from step 7 above |
| `GOOGLE_CLIENT_ID` | Google OAuth app client ID | from GCP Console |
| `GOOGLE_CLIENT_SECRET` | Google OAuth app client secret | from GCP Console |
| `GH_WEBHOOK_SECRET` | HMAC secret for webhook validation | `ruby -e "puts SecureRandom.hex(24)"` |
| `OPENAI_API_KEY` | OpenAI API key (AI features) | from platform.openai.com |

Generate `SECRET_KEY_BASE`:
```bash
bundle exec rails secret
```

Generate `ENCRYPTION_KEY`:
```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(16)"
```

---

## Triggering a deployment

Every push to `main` triggers the full pipeline automatically.

```bash
git push origin main
```

To watch the pipeline:
```
GitHub → Actions → Deploy — Production
```

To deploy manually without a code change:
```bash
git commit --allow-empty -m "chore: trigger deploy"
git push origin main
```

---

## Monitoring and logs

### View Cloud Run logs

```bash
# Web service logs (live tail)
gcloud run services logs tail anchor-prod \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Worker logs
gcloud run services logs tail anchor-worker \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Migration job logs
gcloud run jobs executions list \
  --job=anchor-migrate \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

### Google Cloud Logging (structured)

All logs appear in [Cloud Logging](https://console.cloud.google.com/logs) automatically because `RAILS_LOG_TO_STDOUT=true` is set. Rails and Sidekiq write JSON-structured logs that Cloud Logging parses natively.

Filter by service in Cloud Logging:
```
resource.type="cloud_run_revision"
resource.labels.service_name="anchor-prod"
```

### Health check endpoint

```
GET /up
```

Returns `200 OK` when the app is healthy. This endpoint is used by Cloud Run to determine instance readiness.

---

## Rollback

Cloud Run retains previous revisions. To roll back to the last known-good revision:

```bash
# List revisions
gcloud run revisions list \
  --service=anchor-prod \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Route all traffic to a previous revision
gcloud run services update-traffic anchor-prod \
  --to-revisions=anchor-prod-XXXXXXXX=100 \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

> Note: Rollback reverts the application code but not the database schema. If migrations ran with the new revision, rolling back may leave the schema ahead of the code. Verify compatibility before rolling back after a schema change.

---

## IAM roles — quick reference

| Role | Purpose |
|---|---|
| `roles/artifactregistry.writer` | Push Docker images |
| `roles/run.admin` | Deploy and manage Cloud Run services |
| `roles/run.jobs.admin` | Create and execute Cloud Run Jobs (migrations) |
| `roles/iam.serviceAccountUser` | Impersonate SA when deploying |
| `roles/cloudsql.client` | Connect to Cloud SQL from Cloud Run |

---

## First deploy checklist

- [ ] GCP project created with billing enabled
- [ ] All APIs enabled (`run`, `cloudbuild`, `artifactregistry`, `sqladmin`)
- [ ] Artifact Registry repository `anchor` created in the target region
- [ ] Service account `github-actions` created with all 5 IAM roles
- [ ] `gcp-sa-key.json` exported, copied to `GCP_SA_KEY` secret, local file deleted
- [ ] Cloud SQL instance and database created
- [ ] Redis provisioned (Redis Cloud or Memorystore)
- [ ] All 14 GitHub Secrets created and verified
- [ ] GitHub OAuth App created with production callback URL
- [ ] Google OAuth App created with production callback URL
- [ ] Push to `main` and confirm green pipeline in GitHub Actions
- [ ] Visit the Cloud Run URL printed in the deploy summary step
- [ ] Update GitHub and Google OAuth callback URLs if the URL changed from first deploy

---

## Troubleshooting

**Migration job fails with "permission denied"**
The service account is missing `roles/cloudsql.client`. Add it and redeploy.

**"Image not found" error during deploy**
The Artifact Registry push succeeded but the region in `GCP_REGION` doesn't match the registry path. Confirm the image path is `REGION-docker.pkg.dev/PROJECT/anchor/app`.

**Web service starts but returns 500**
`RAILS_MASTER_KEY` is wrong or missing. The credentials file can't be decrypted. Verify the secret matches `config/master.key` locally.

**Sidekiq worker not processing jobs**
Check `REDIS_URL_PROD` — the worker and web service must connect to the same Redis instance. Tail the worker logs to confirm it's polling.

**Cold start latency**
Set `--min-instances=1` on `anchor-prod` in `deploy-prod.yml` to keep one instance warm. This increases cost slightly but eliminates cold starts.
