# Google Cloud setup

> **This is the paid path.** Everything on this page creates resources in a Google Cloud project that
> Google bills you for. To try Anchor for free, use the Local Docker provider
> ([docs/quickstart.md](docs/quickstart.md)).

Anchor uses Google Cloud in two separate ways:

- [**Part 1: deploy your apps to Cloud Run.**](#part-1-deploy-your-apps-to-cloud-run) Anchor, running
  anywhere (even on your laptop), builds and runs your apps in *your* GCP project.
- [**Part 2: host Anchor itself on Cloud Run.**](#part-2-host-anchor-itself-on-cloud-run) The GitHub
  Actions workflows in this repo deploy the Anchor web app and worker to Cloud Run.

You can do either one without the other.

---

## Part 1: deploy your apps to Cloud Run

### What it costs

In your project, Google bills for:

- **Cloud Build** minutes for every deploy.
- **Artifact Registry** storage for the images.
- **Cloud Run** usage for your running apps. Anchor deploys them with `--min-instances=0`, so an app
  with no traffic scales to zero.

Anchor itself charges nothing. Preflight errors stop a deploy *before* Cloud Build runs, so a deploy
that is certain to fail doesn't cost a build.

### 1. Create a project with billing

1. In the [Cloud Console](https://console.cloud.google.com/projectcreate), create a project and note
   its **project ID**.
2. Link a billing account to it under **Billing**. Cloud Run and Cloud Build need billing enabled,
   even within the free tier.

Optionally, `bash scripts/setup_gcloud.sh` checks that the `gcloud` CLI is installed and signed in, and
lists your projects.

### 2. Make sure the Anchor worker has `gcloud`

The Cloud Run provider runs the `gcloud` CLI on the Anchor worker, as you. The production image
already includes it. If you run Anchor locally with `bin/dev`, install the
[Google Cloud CLI](https://cloud.google.com/sdk/docs/install) on that machine. Anchor passes your
credentials to each `gcloud` call, so you don't need to run `gcloud auth login` for Anchor.

### 3. Connect Google Cloud in Anchor

Under **Settings → Google Cloud**, choose one of:

- **Connect with Google OAuth.** This requires `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` on the
  Anchor server, and a Google OAuth client with the callback `<anchor-url>/auth/google_oauth2/callback`.
  It requests the `cloud-platform` scope, which gives access to every project you can reach. You can
  override the scope with `GOOGLE_OAUTH_SCOPE`.
- **Paste a service-account key (JSON).** This is narrower, because the key works only in the one
  project. The UI asks for a service account with the **Editor** role.

The credentials are encrypted at rest. They are currently AES-256-CBC through `attr_encrypted`, and
moving them to GCM is on the roadmap (see [docs/threat-model.md](docs/threat-model.md)).

### 4. Create a project in Anchor and deploy

Go to **Projects → Deploy new app**, pick a repo, choose **Google Cloud Run**, and set the GCP
project ID and a region (`us-central1`, `us-east1`, `us-west1`, `europe-west1`, `europe-west2`,
`europe-west3`, `asia-east1`, or `asia-northeast1`).

The first deploy provisions the project once. It enables `cloudbuild`, `run`, `artifactregistry`,
`secretmanager`, `storage`, `iam`, and `cloudresourcemanager`, and it creates the Artifact Registry
repository. After that, every deploy works like this:

1. `gcloud builds submit --async` builds the image, and Anchor polls the build.
2. `gcloud run deploy --no-traffic --tag=d<id>` creates a revision with **no traffic**, reachable
   only at its tagged URL.
3. Anchor health-checks that URL. On success it runs
   `gcloud run services update-traffic --to-revisions=<rev>=100`. On failure it deletes the revision,
   and the previous revision keeps serving.

### Know the limits

- The **first** deploy of a new service can't use `--no-traffic`, because Cloud Run rejects it when it
  creates a service. That revision gets traffic before its health check runs.
- Your app's secrets are set as **plain environment variables** on the revision (`--env-vars-file`).
  Anyone with `run.services.get` on the project can read them. Secret Manager support for deployed
  apps isn't built yet.
- If you set `public_access = false`, the service is private (`--no-allow-unauthenticated`). The
  health check sends no identity token, so a 403 counts as "up".
- Memory (`512Mi`), health check path (`/`), and public access are shown by the API but can't be changed from the UI or API yet.

---

## Part 2: host Anchor itself on Cloud Run

`.github/workflows/deploy-prod.yml` runs on pushes to `main`, and `deploy-staging.yml` runs on pushes
to `staging`. Each one runs the tests and a security scan, builds and pushes the image, runs
migrations as a Cloud Run Job, and then deploys the **web** service and the **worker** service.

For the one-time infrastructure (APIs, Artifact Registry, the deploy service account and its roles,
Cloud SQL, Redis, and OAuth apps), follow [docs/deployment.md](docs/deployment.md). The rest of this
section covers what changed in 0.2.0.

### What it costs

| Service | Setting | Cost |
|---|---|---|
| Web (`anchor-prod` / `anchor-staging`) | `--min-instances=0`, 256Mi, CPU throttled | Scales to zero. You pay per request. |
| **Worker** (`anchor-worker` / `anchor-worker-staging`) | **`--min-instances=1`**, 1 vCPU, 512Mi, `--no-cpu-throttling` | **About $45–55 per month per environment** at us-central1 list prices, before free tier |
| Migrations (`anchor-migrate`) | Cloud Run Job, runs once per deploy | Small |
| Cloud SQL, Redis, Artifact Registry, Secret Manager | See docs/deployment.md | Depends on the tier |

**The worker has to stay at `--min-instances=1`.** Sidekiq pulls jobs from Redis, and nothing wakes a
worker that has scaled to zero. With 0 instances, queued deployments would hang forever. The stuck-deployment
reaper runs on the worker too, so it can't rescue them. Running production and staging means two always-on workers.

### Runtime secrets come from Secret Manager

The workflows no longer pass secrets as plaintext `--set-env-vars`. Cloud Run resolves them from
Secret Manager when an instance starts (`--set-secrets`), so they never appear in the revision spec,
the Cloud Console, or `gcloud run services describe`.

**Before the first deploy with this version**, create the secrets in each environment's project. The
prefix is `anchor-prod` or `anchor-staging` (`SECRET_PREFIX` in the workflow):

| Secret Manager name | Becomes env var | Used by |
|---|---|---|
| `<prefix>-rails-master-key` | `RAILS_MASTER_KEY` | migrate, web, worker |
| `<prefix>-secret-key-base` | `SECRET_KEY_BASE` | migrate, web, worker |
| `<prefix>-encryption-key` | `ENCRYPTION_KEY` | migrate, web, worker |
| `<prefix>-database-url` | `DATABASE_URL` | migrate, web, worker |
| `<prefix>-redis-url` | `REDIS_URL` | web, worker |
| `<prefix>-github-client-secret` | `GITHUB_CLIENT_SECRET` | web, worker |
| `<prefix>-google-client-secret` | `GOOGLE_CLIENT_SECRET` | web, worker |
| `<prefix>-anthropic-api-key` | `ANTHROPIC_API_KEY` (default AI provider) | web, worker |
| `<prefix>-openai-api-key` | `OPENAI_API_KEY` | web, worker |
| `<prefix>-github-webhook-secret` | `GITHUB_WEBHOOK_SECRET` | web |

For example (run this yourself; Anchor never does):

```bash
printf '%s' "$VALUE" | gcloud secrets create anchor-prod-encryption-key \
  --project="$PROJECT_ID" --replication-policy=automatic --data-file=-
```

The workflows reference every secret above, so each one has to exist. Create
`<prefix>-anthropic-api-key` and `<prefix>-openai-api-key` even if you don't use AI; any placeholder
value works. With no real key set, the AI features switch themselves off.

Then:

1. Grant the Cloud Run **runtime** service account `roles/secretmanager.secretAccessor`.
2. If a service already has any of these as plain env vars from an older deploy, remove them once.
   Cloud Run won't change a variable's type in place:

   ```bash
   gcloud run services update anchor-prod --region="$REGION" --project="$PROJECT_ID" \
     --remove-env-vars=RAILS_MASTER_KEY,SECRET_KEY_BASE,ENCRYPTION_KEY,DATABASE_URL,REDIS_URL,GITHUB_CLIENT_SECRET,GOOGLE_CLIENT_SECRET,OPENAI_API_KEY,GITHUB_WEBHOOK_SECRET
   ```

   Do the same for the worker.

### How deploys run

**Deploys are off by default.** Hosting Anchor on GCP costs money (at minimum the always-on worker),
so the deploy workflows skip the deploy job, and only run CI, until you set the repository variable
`ANCHOR_DEPLOY_ENABLED` to `true` (Settings → Secrets and variables → Actions → Variables). Do that
only after billing and the one-time setup below are in place.

`deploy-staging.yml` (push to `staging`) and `deploy-prod.yml` (push to `main`) both run the full CI,
including the end-to-end suite, then the shared `_deploy.yml`:

1. build and push the image, tagged with the commit SHA
2. run migrations as a Cloud Run Job (CI blocks migrations that would break the revision still serving)
3. deploy a new web revision with **no traffic** and smoke-test `/healthz` and `/readyz` on its tagged URL
4. shift 100% of traffic, verify the public `/readyz`, deploy the worker, verify again
5. on any failure after step 3, **roll traffic back** to the previous revision automatically

The very first deploy of a service can't use `--no-traffic` (Cloud Run refuses it when creating a
service), so it gets traffic immediately; there is nothing older to fall back to.

### Require approval for production

In **Settings → Environments**, create `staging` and `production`. On `production`, add
**Required reviewers** (and optionally restrict it to the `main` branch). Every production deploy then
waits for a reviewer to press *Approve* after CI passes.

### Authenticate without a key (recommended)

Use Workload Identity Federation instead of a long-lived JSON key. Run these yourself (Anchor never does):

```bash
gcloud iam workload-identity-pools create github --location=global --project="$PROJECT_ID"
gcloud iam workload-identity-pools providers create-oidc github --location=global \
  --workload-identity-pool=github --project="$PROJECT_ID" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='<owner>/<repo>'"
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" --project="$PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/<owner>/<repo>"
```

Then set two **repository variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<number>/locations/global/workloadIdentityPools/github/providers/github` |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | the deploy service account's email |

When `GCP_WORKLOAD_IDENTITY_PROVIDER` is set, the workflows use it and ignore `GCP_SA_KEY`; delete the
key afterwards.

### GitHub Actions secrets

Only these are read from GitHub. Everything else comes from Secret Manager.

| GitHub secret | Purpose |
|---|---|
| `GCP_PROJECT_ID` | Target project |
| `GCP_REGION` | For example `us-central1` |
| `GCP_SA_KEY` | Legacy: JSON key of the deploy service account. Not needed with Workload Identity Federation |
| `GH_CLIENT_ID` | GitHub OAuth app client ID (not secret, passed as a plain env var) |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID (not secret, passed as a plain env var) |

### Releases

Push a tag like `v0.2.0`. `release.yml` runs CI, then publishes a GitHub Release with CLI binaries for
Linux, macOS and Windows, the MCP server package (`anchor-mcp-<version>.tgz`) and `SHA256SUMS`.

### Recommended production settings

- Set `APP_HOSTS` to your domain so Host-header attacks can't poison OAuth or webhook URLs.
- Prefer dedicated `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`,
  and `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` keys (`bin/rails db:encryption:init`) over the
  keys derived from `ENCRYPTION_KEY`. The workflows don't wire these up yet, so add them as Secret
  Manager secrets and `--set-secrets` entries.
- Leave `ANCHOR_ALLOW_GLOBAL_WEBHOOK_SECRET` unset.
- Point uptime checks at `/healthz` (liveness) and alerts at `/readyz`. See [docs/runbook.md](docs/runbook.md)
  and [docs/slo.md](docs/slo.md).
