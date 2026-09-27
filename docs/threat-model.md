# Anchor threat model

Last reviewed: 2026-09. Owner: AppSec. Method: assets → trust boundaries →
STRIDE per boundary → mitigations and open gaps. Update this file when you add
a credential type, an external integration, or a new way for untrusted input to
reach a job, a shell, or an LLM.

## 1. What Anchor is, from an attacker's point of view

Anchor takes a GitHub repository and deploys it into **the user's own cloud
account**. To do that it holds long-lived credentials for two very valuable
systems at once: the user's source code (GitHub) and the user's cloud (GCP). One
database row can be enough to read private code, push to it, and run arbitrary
workloads billed to the victim. That is why Anchor is a high-value target, and
it's the first thing a BYOC buyer will ask about.

## 2. Assets

| # | Asset | Where it lives | Impact if stolen |
|---|---|---|---|
| A1 | GitHub OAuth token (`repo`, `workflow`, `user:email`) | `users.encrypted_github_token` | Read/write **every** repo the user can reach; add workflows that steal Actions secrets |
| A2 | Google OAuth access + refresh token (`cloud-platform`) | `users.encrypted_google_*` | Full control of every GCP project the user can reach, until the refresh token is revoked |
| A3 | GCP service-account JSON key | `users.encrypted_gcp_service_account_key` | Whatever roles the SA has (today: deploy + build + registry in one project); keys don't expire |
| A4 | Project secrets (app env vars) | `secrets.value` (AR Encryption) / legacy `secrets.encrypted_value` | Customer databases, payment keys, third-party APIs |
| A5 | Webhook secrets | `projects.webhook_secret` (Active Record Encryption, AES-256-GCM) | Trigger deploys of any commit on the production branch |
| A6 | Anchor API tokens (`anc_…`) | `api_tokens.token_digest` (SHA-256) | Everything the CLI/MCP API allows for that user |
| A7 | Platform keys: `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, AR encryption keys, OAuth client secrets, `OPENAI_API_KEY` | Env vars on Cloud Run / GitHub Actions secrets | Decrypt A1–A4 in bulk, forge sessions, impersonate the OAuth app |
| A8 | Deployment logs and AI explanations | `deployment_logs`, `deployments.ai_explanation` | Often contain echoed secrets / tokens; also sent to OpenAI |
| A9 | Integrity of the deployed artifact | Cloud Build / Artifact Registry / Cloud Run in the customer project | Supply-chain compromise of the customer's production |

## 3. Trust boundaries

```
 Browser ──(TB1: HTTPS, session cookie, CSRF, CSP)──► Rails web ──► Postgres (A1–A6, A8)
 CLI / MCP agent ──(TB2: Bearer anc_ token)────────► /api/v1       └► Redis (Sidekiq, Rack::Attack)
 GitHub ──(TB3: HMAC X-Hub-Signature-256)─────────► /webhooks/github
 Rails / Sidekiq ──(TB4: user's GitHub token)──────► GitHub API, git clone
 Sidekiq ──(TB5: user's Google token / SA key)─────► Customer GCP: Cloud Build, Artifact Registry, Cloud Run
 Repository content ──(TB6: UNTRUSTED)─────────────► analysis, Dockerfile generation, build, LLM prompts
 Sidekiq ──(TB7: prompt with repo content + logs)──► OpenAI API ──► text shown to user / files committed
 Customer app at runtime ──(TB8: env vars)─────────► secrets A4 (visible in Cloud Run revision config)
```

The most overlooked boundary is **TB6**: everything inside the repository
(README, Dockerfile, package scripts, test output, file names) is controlled by
whoever can push to it. That includes outside contributors whose PRs get
merged, compromised dependencies, and anyone who deploys a repo they don't own.
Repository content flows into three sensitive sinks: shells (build steps), the
LLM (TB7), and — via the LLM — commits back to GitHub.

## 4. STRIDE

### TB1 — Browser ↔ web app

| Threat | Mitigation in place | Gap / follow-up |
|---|---|---|
| **S**poofing: session theft / fixation | Encrypted cookie session; `reset_session` on login, logout and Google link; `secure`, `httponly`, `SameSite=Lax`; HSTS 1y | No server-side session expiry — add `authenticated_at` max-age check in `ApplicationController` |
| **S**: login CSRF | OmniAuth request phase is POST-only + CSRF token; `state` checked on callback | — |
| **T**ampering: CSRF on state-changing actions | Rails CSRF on all controllers except webhooks | — |
| **I**nfo disclosure: XSS exfiltrating tokens / triggering deploys | ERB autoescape; enforced CSP (nonce + hashed static inline scripts, `object-src 'none'`, `frame-ancestors 'none'`, `form-action` pinned to self + OAuth hosts) | Move layout inline scripts and `onclick=` handlers into Stimulus, then drop hash allowances |
| **I**: open redirect after login | `return_to` must be a same-origin path (`//`, `/\`, schemes rejected) | — |
| **I**: Host-header poisoning of OAuth/webhook URLs | `config.hosts` from `APP_HOSTS` | Operators must set `APP_HOSTS` |
| **D**oS | Rack::Attack per-IP, per-user deploy/analyze/sync limits | — |
| **E**levation: IDOR | Controllers scope through `current_user.projects` | Keep request specs for every new resource (see `spec/requests/secrets_spec.rb`) |

### TB2 — API tokens (CLI / MCP)

| Threat | Mitigation | Gap |
|---|---|---|
| **S**: token guessing / reuse | Tokens stored as SHA-256 digest, shown once, `anc_` prefix (scannable by GitHub secret scanning and by `Security::Redactor`), revocable | No scopes yet: every token is full-account. Add read-only / per-project scopes before promoting MCP use |
| **D**: runaway agent | Rack::Attack `api/token` (600/5 min per token digest), `api/deploy/token` (30/h), `api/ip` backstop | — |
| **R**epudiation | `last_used_at` | Record token id on deployments (`triggered_by: "cli"`) and in an audit log |

### TB3 — GitHub webhooks

| Threat | Mitigation | Gap |
|---|---|---|
| **S**: forged push triggers a deploy | HMAC-SHA256 with the **project's** secret, constant-time compare; SHA-1 header not accepted; global shared secret only if `ANCHOR_ALLOW_GLOBAL_WEBHOOK_SECRET=true` | — (A5 encrypted at rest since 0.2.0; legacy rows migrated in place) |
| **T**: payload for repo X signed with project Y's secret | With `?project=<slug>` the signature is checked first, then the payload's repository must match | Legacy URL without `?project=` still accepted for existing hooks; the UI now shows the slugged URL |
| **R**/**D**: replay / redelivery storm | `X-GitHub-Delivery` claimed in `webhook_deliveries` (unique index, same transaction as the deployment); 5 MB body cap; exempt from per-IP throttle (GitHub shares IPs across all customers) | Schedule `WebhookDelivery.prune!`; note that a replayed *new* delivery id with a captured body+signature still verifies — GitHub doesn't sign a timestamp |
| **D**: malformed input → 500 | Invalid JSON → 400, non-object JSON → 400, odd field types tolerated | — |

### TB4/TB5 — Anchor acting with the user's GitHub and Google credentials

| Threat | Mitigation | Gap |
|---|---|---|
| **I**: token leaks via clone URL in logs / errors | Clone URL redacted in `PrepareJob`; `Security::Redactor` available | — (`PrepareJob` deletes `.git`, including the tokened remote in `.git/config`, right after reading commit metadata, so it never reaches the build context) |
| **E**: over-broad OAuth scopes | Scopes documented and overridable (`GITHUB_OAUTH_SCOPE`, `GOOGLE_OAUTH_SCOPE`) | See §6 — move to a GitHub App and to service accounts / WIF |
| **I**: bulk DB theft | App-level encryption of A1–A4 (see §5) | Keys (A7) live in the same Cloud Run env as the app — use Secret Manager + a KMS-wrapped key |
| **T**: command injection in gcloud/git invocations | `Shellwords.escape` on interpolated values; `--env-vars-file` instead of `--set-env-vars` | Brakeman flags `PrepareJob#run_git!` / `#capture_git!` string commands — switch to argv arrays (`Open3.capture2e("git", …)`) |

### TB6/TB7 — Untrusted repository content and the LLM

| Threat | Mitigation | Gap |
|---|---|---|
| **T**: prompt injection in README / file names steers analysis (env vars, commands, ports) | Analysis output is shown to the user before deploy | Treat LLM output as untrusted input: validate against schemas and allowlists |
| **E**: prompt-injected CI/CD generator commits arbitrary files (e.g. a workflow that exfiltrates Actions secrets) with the user's `repo`+`workflow` token | `Security::GeneratedFilePolicy` allowlists paths (Dockerfile, .dockerignore, `.github/workflows/*.yml`) and rejects `pull_request_target`, `toJSON(secrets)`, `${{ github.event.* }}` interpolation, `curl | sh`, `write-all` | Wired into `ProjectsController#commit_cicd`, which refuses on any violation. Still to do: show a diff and require explicit confirmation |
| **I**: secrets sent to a third party in prompts | — | Done: `Deployment#append_log` redacts project secret values, the owner's GitHub token and known credential patterns before storing or broadcasting, and every prompt goes through `Ai::Redaction` → `Security::Redactor`. Residual: pattern-based redaction can miss unusual secret formats |
| **I**: log injection → LLM output shown in the UI | Output rendered via ERB (escaped) | Never render LLM output with `raw` / `html_safe` |
| **E**: build steps run attacker code | Builds run in the customer's Cloud Build, not on Anchor workers | Local Docker provider runs builds on the Anchor host — sandbox it (rootless, no host mounts, no Anchor env vars in build args) |

### TB8 — Deployed application

| Threat | Mitigation | Gap |
|---|---|---|
| **I**: every deployed service is public | — | `DeployToCloudRunJob` hardcodes `--allow-unauthenticated`; honour `project.public_access` and default to private for new projects |
| **I**: secrets visible as plain env vars | YAML env file avoids injection | Anyone with `run.services.get` in the project can read them; use Secret Manager + `--set-secrets` |

## 5. Encryption at rest

**Before:** `attr_encrypted` 4.x, AES-256-CBC, key = `SHA256(ENCRYPTION_KEY)`,
random IV per write. Problems:

- CBC with **no authentication tag**: ciphertext can be modified undetected
  (bit-flipping, padding-oracle exposure if decrypt errors are ever observable).
- Plain SHA-256 is not a KDF, and there's no key id in the ciphertext, so the
  key **can't be rotated** without a big-bang re-encryption and downtime.
- One key protects every column and every tenant.

**Now (Secret):** Active Record Encryption — AES-256-GCM (authenticated),
per-message random IV, key derived with PBKDF2-SHA256, and a list of primary
keys where the last one encrypts and all of them decrypt (rotation). Keys come
from `ACTIVE_RECORD_ENCRYPTION_*` env vars, else credentials, else are derived
from `ENCRYPTION_KEY` with per-purpose salts (`config/initializers/active_record_encryption.rb`).

Migration, designed so it never breaks existing data and is safe to roll back:

1. **Phase 1 (this change).** New nullable `secrets.value` column. Reads try
   GCM first, then fall back to the legacy CBC columns. Writes go to GCM **and**
   still refresh the legacy columns (`ANCHOR_SECRET_LEGACY_WRITES` defaults to
   `true`), so the previous release can still read everything if we roll back.
   Run `bin/rails runner 'Secret.reencrypt_legacy!'` — idempotent, row-locked,
   returns the number of rows migrated.
2. **Phase 2 (after one clean release).** Set `ANCHOR_SECRET_LEGACY_WRITES=false`,
   re-run `Secret.reencrypt_legacy!`, then null out `encrypted_value` /
   `encrypted_value_iv` for every row that has `value`.
3. **Phase 3.** Drop the legacy columns and the `attr_encrypted` declaration.

**Follow-up: User tokens** (`github_token`, `google_access_token`,
`google_refresh_token`, `gcp_service_account_key`) use the same pattern: add
`github_token` etc. as new text columns with `encrypts`, rename the
`attr_encrypted` attributes to `legacy_*` with `attribute: "encrypted_*"`, add
dual-read accessors, backfill, then remove. Two details specific to `User`:
`User.from_omniauth` has a "corrupted IV" repair path that should be deleted
once CBC is gone; and the Google token refresh path writes under a row lock,
which the backfill must respect (use `with_lock`, as `Secret.reencrypt_legacy!`
does). Once `gem "attr_encrypted"` has no users, remove it.

**Key management target:** keep `ACTIVE_RECORD_ENCRYPTION_*` in Secret Manager,
mounted only into the web and worker services; rotate yearly and on staff
change by appending a new primary key, re-encrypting, then removing the old one.

## 6. OAuth scopes and least privilege

**GitHub** — today an OAuth App with `user:email,repo,workflow`.
`repo` is read/write to **all** of a user's public and private repositories;
`workflow` lets Anchor change CI config. Needed for: cloning private repos,
creating webhooks, committing generated CI files.

Proposal: move to a **GitHub App**. The user installs it on selected repos only;
permissions are `contents: read` (write only if CI commit is enabled),
`metadata: read`, `webhooks: write` (or app-level webhooks, which removes
per-project webhook secrets altogether), `workflows: write` only when needed.
Installation tokens last one hour and are minted on demand, so the database
holds no long-lived GitHub credential at all. Until then operators who don't
use CI setup can set `GITHUB_OAUTH_SCOPE="user:email,repo"`.

**Google** — `cloud-platform` is effectively "act as this user on every GCP
project they can reach", and the refresh token doesn't expire. It's the most
dangerous credential Anchor holds.

Proposal, in order of preference:

1. **Workload Identity Federation (keyless).** The customer creates a service
   account in *their* project with only `roles/run.admin` (or `run.developer`),
   `roles/cloudbuild.builds.editor`, `roles/artifactregistry.writer` and
   `roles/iam.serviceAccountUser` on the runtime SA. They grant Anchor's
   identity (an OIDC issuer Anchor controls, or Anchor's own GCP service
   account) `roles/iam.workloadIdentityUser` on it. Anchor exchanges a
   short-lived token per job — nothing long-lived is stored, and the customer
   can see and revoke access in their own IAM.
2. **Service-account impersonation.** Same customer-owned SA; grant Anchor's
   platform SA `roles/iam.serviceAccountTokenCreator` on it. One-hour tokens.
3. **Customer-uploaded SA key** (supported today). Least-privilege roles as
   above, but a non-expiring key in our DB — acceptable only as a fallback.

Keep OAuth + `cloud-platform` only for the one-time bootstrap that creates the
SA and WIF binding, then **revoke** the refresh token. This matches how Defang,
Porter and Qovery onboard AWS/GCP accounts, and it's the answer BYOC buyers
expect.

## 7. Redaction

`Security::Redactor.redact(text, secrets: [...])` removes:

- exact values supplied by the caller (and their URL-encoded / Base64 forms);
- credentials in URLs (`https://x-access-token:…@`, `postgres://user:pw@`);
- `Authorization:` headers and `Bearer …` tokens;
- GitHub (`ghp_/gho_/ghu_/ghs_/ghr_`, `github_pat_`), OpenAI (`sk-`, `sk-proj-`),
  Anthropic (`sk-ant-`), Google (`AIza…`, `ya29.…`, `1//0…` refresh tokens),
  AWS access key ids, Slack, Stripe and Anchor (`anc_`) tokens;
- PEM private key blocks and `"private_key"` / `"private_key_id"` fields of
  service-account JSON;
- `SOMETHING_SECRET=…`-style assignments.

Where it is applied: `Deployment#append_log` (so stored and streamed logs and
the API log endpoint are covered) and every prompt built in `app/services/ai/*`.
Still to cover: `error_message` writes and exception messages sent to logs or
error trackers.

## 8. Supply chain and platform

- `bundle-audit`: clean as of 2026-09-27 after patch-level updates (rails
  8.1.4, rack 3.2.7, puma 7.2.1, nokogiri 1.19.4, jwt 3.3.0, mcp 0.25.0). CI
  runs it on every PR.
- `brakeman -w2`: no warnings. Git commands are now built as argument arrays,
  so no shell is involved.
- CI deploy workflows read Anchor's own secrets from Secret Manager
  (`--set-secrets`). They use Workload Identity Federation when the
  `GCP_WORKLOAD_IDENTITY_PROVIDER` variable is set and fall back to the JSON
  key (`GCP_SA_KEY`) otherwise. Set up WIF (SETUP_GCLOUD.md) and delete the key.
- `GITHUB_WEBHOOK_SECRET` is still deployed to production; once no project
  relies on it, remove it from the workflow and the environment.
