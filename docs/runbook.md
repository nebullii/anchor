# Anchor Runbook

On-call guide for operating Anchor itself (web + Sidekiq worker + Postgres + Redis)
and for the user deployments it drives. Targets are in [slo.md](slo.md).

## Quick reference

| What | Where |
|---|---|
| Liveness (process up, no deps) | `GET /healthz` → `{"status":"ok"}` |
| Readiness (DB, Redis, worker heartbeat, queue latency) | `GET /readyz` → 200 / 503 with per-check JSON |
| Job dashboard | `/sidekiq`, only for GitHub logins in `ANCHOR_ADMIN_GITHUB_LOGINS` (404 for everyone else) |
| Console snippets below | `bin/rails console` locally, or `bin/rails runner '...'` as a one-off job in production |

Probe wiring: point the web service's **liveness/startup** probe at `/healthz`. Point
**uptime monitoring/alerting** at `/readyz`. Don't use `/readyz` as the web liveness
probe: a worker outage would then restart healthy web containers.

`/readyz` tunables: `READYZ_MAX_QUEUE_LATENCY` (seconds, default 300). A worker
counts as alive if its Sidekiq heartbeat is under 60s old.

## Release flow (what "running" means)

```
queued → analyzing → building → deploying → health_check → running
                                   │             │
                                   │             └─ fail → failed (error_category=health_check),
                                   │                       revision deleted, old revision keeps serving
                                   └─ deploy_revision! creates a revision with 0% traffic
```

A deployment is `running` only after its revision answered the health check
and `promote!` moved 100% of traffic to it. Health check = `GET <revision_url><project.health_check_path>`,
healthy if the status is < 500 and not 429, and the body isn't a platform/proxy error page.
Retries back off 5, 10, 15, 20, 25, 30, 30s via re-enqueued `HealthCheckJob`s. No thread sleeps.
Tunables: `HEALTH_CHECK_ATTEMPTS` (default 8), `HEALTH_CHECK_BUDGET_SECONDS` (default 150).

---

## 1. Stuck deployments

**Symptom:** a deployment shows `analyzing` / `building` / `deploying` / `health_check` for
more than 35 minutes, or the user can't deploy ("already in progress").

1. Check `/readyz`. If `sidekiq.ok` is false or `queues.max_latency` is high, go to §4 (worker down).
2. Open `/sidekiq` → Scheduled. A `Deployments::HealthCheckJob` or `PollBuildStatusJob` for the
   deployment means it's still progressing. Retries → the job is erroring; read the error.
3. Look at the deployment's last log lines on its page.
4. If nothing is queued or scheduled for it, the chain is broken. Cancel it from the UI
   (Cancel button) or from the console:
   ```ruby
   d = Deployment.find(ID); d.append_log("Cancelled by on-call: pipeline stalled", level: "warn"); d.transition_to!("cancelled")
   ```
   The previous revision keeps serving, so users see no impact. Ask the user to redeploy.
5. If it's stuck in `health_check`, cancel it. The next `HealthCheckJob` run deletes the unpromoted revision.

## 2. Failed health checks

**Symptom:** deployment `failed`, `error_category = "health_check"`, message says
"The new revision was NOT promoted; the previous revision is still serving traffic."

No user-facing outage: traffic never moved. Triage with the user:

1. Read the last health check result in the logs (`HTTP 503`, `Net::OpenTimeout`, `platform proxy`, …).
2. Common causes:
   - App doesn't listen on `$PORT` → `Errno::ECONNREFUSED` / proxy 404/503.
   - Slow boot (migrations or asset compile at startup) exceeds the ~2.5 min budget. Move work
     out of boot, or raise `HEALTH_CHECK_BUDGET_SECONDS` globally.
   - `health_check_path` returns 5xx (e.g. `/up` checks a DB the app can't reach) → check secrets.
   - Missing required env var → crash on boot → 503.
3. If the revision wasn't cleaned up (log line "Could not delete revision"), it has no traffic and
   is harmless. Delete it later from the provider console.

## 3. Rollback

**User path (one click):** open any previously healthy deployment → **Roll back to this
deployment**. With no target given (API/CLI), Anchor uses the newest healthy deployment whose
revision differs from the live one.

- Creates a new deployment (`triggered_by: rollback`) → `RollbackJob` → `provider.rollback!` shifts
  traffic to the old revision (no rebuild; normally a few seconds).
- On success the new deployment becomes `running` and the previously live one becomes `rolled_back`.
- On failure the rollback deployment is `failed` and traffic is **unchanged**.

**Operator path** (UI unavailable):
```ruby
Deployments::Rollback.new(project: Project.find(ID), user: User.find_by(github_login: "you"),
                          target: DEPLOYMENT_ID_OR_NIL).call
```
Rollback is refused while another deployment is in progress. Cancel that one first (§1).

Rollback only restores the **container revision**. It does not undo database migrations or
secret changes the user made in the meantime.

## 4. Worker down

**Symptom:** `/readyz` → `sidekiq.ok: false` or growing `queues.max_latency`. Deployments sit in `queued`.

1. Check the worker service (`anchor-worker`) is running with **min instances ≥ 1**. Sidekiq polls
   Redis and cannot be woken by HTTP, so scale-to-zero leaves jobs stranded.
2. Check worker logs for boot errors (missing env var, Redis auth, DB connection limit).
3. Restart or redeploy the worker. Jobs in Redis survive and resume: health checks continue from
   their scheduled attempt. If the downtime ran past the health check budget, the check fails and
   the deployment is marked failed, so a revision nobody verified never gets promoted.
4. After recovery, look for deployments left in progress with nothing scheduled (§1).

## 5. Redis down

**Symptom:** `/readyz` → `redis.ok: false`. `/healthz` still OK. Enqueues fail (deploy buttons
error). ActionCable log streaming stops. Rack::Attack can't count requests.

1. Check the Redis instance (Memorystore / Upstash / container) status and `REDIS_URL`.
2. The web app stays up. Tell users that deploys and live logs are paused.
3. When Redis comes back: if data was lost (non-persistent Redis), queued and scheduled jobs are
   gone. Find orphans:
   ```ruby
   Deployment.in_progress.where("updated_at < ?", 10.minutes.ago)
   ```
   Cancel them (§1) and ask users to redeploy. Deployments caught in `health_check` never
   promoted, so the old revision is still live.

## 6. Key rotation

| Secret | Impact of rotation | Procedure |
|---|---|---|
| `SECRET_KEY_BASE` | All sessions invalidated (users re-login) | Set new value, redeploy web + worker. |
| `GITHUB_CLIENT_SECRET` | OAuth login | Regenerate in GitHub OAuth app, update env, redeploy web. |
| Project `webhook_secret` | GitHub push webhooks for that project | Regenerate on project, update the webhook in the GitHub repo. |
| `ANCHOR_ADMIN_GITHUB_LOGINS` | Sidekiq dashboard access | Edit env and redeploy. Takes effect on the next request. |
| `ENCRYPTION_KEY` | Encrypts `Secret#value` and user tokens (attr_encrypted, AES-256-CBC, single key) | See below. There is no dual-key support, so rotating needs a short maintenance window. |

**ENCRYPTION_KEY rotation**

1. Pause deploys: scale the worker to 0 and put the web app in maintenance (or accept brief errors).
2. Take a DB backup.
3. Re-encrypt in a single runner process. The key proc reads `ENV` on every call:
   ```ruby
   # OLD=... NEW=... bin/rails runner rotate.rb
   ENV["ENCRYPTION_KEY"] = ENV.fetch("OLD")
   secrets = Secret.find_each.map { |s| [ s, s.value ] }
   users   = User.find_each.map { |u| [ u, %i[github_token google_access_token google_refresh_token gcp_service_account_key].to_h { |a| [ a, u.public_send(a) ] } ] }
   ENV["ENCRYPTION_KEY"] = ENV.fetch("NEW")
   ActiveRecord::Base.transaction do
     secrets.each { |s, v| s.update!(value: v) }
     users.each   { |u, h| u.update!(h) }
   end
   ```
4. Set `ENCRYPTION_KEY=NEW` on web and worker, redeploy, and verify: open a project's Secrets page
   and run a test deploy.
5. Destroy the old key only after the verification passes.

Stored cloud credentials (GCP service-account keys) belong to users. If one leaks, the user must
revoke it in their cloud console and re-upload it in Settings.
