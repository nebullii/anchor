# Anchor — Scaling Design

## Target

**100,000 deployments per month** while keeping V1 a simple Rails monolith.

This document defines what V1 deliberately defers, what breaks first as usage grows,
and the concrete changes needed at each scale tier. Every architectural decision is
traced back to a real load number.

---

## Load Model

Work backwards from 100k deployments/month:

```
100,000 deployments/month
  ÷ 30 days             = 3,333 deployments/day
  ÷ 24 hours            = 139/hour average
  × 5x peak factor      = 695/hour peak  (~12/minute)

Each deployment = 5 Sidekiq job steps
  → 695 × 5            = 3,475 job executions/hour peak
  → 58 jobs/minute peak (~1 job/second)

Average build time: 5 minutes
  → 695 builds/hour × 5 min = 3,475 concurrent build-minutes
  → ~58 deployments in-flight at any moment (peak)

Log lines per deployment: ~200 average
  → 100,000 × 200       = 20,000,000 log rows/month
  → 240,000 rows/day
  → ~2.8 rows/second (average write rate)

Live viewers: 30% of deployments watched in browser
  → 58 in-flight × 0.30 = ~17 concurrent WebSocket connections (peak)
```

**Conclusion:** The load is not extreme. The monolith handles this. The real constraints
are GCP quota limits, log table growth, and database connection pool exhaustion — not
raw throughput.

---

## What Breaks First (in order)

| Failure mode | Trigger | Scale tier |
|---|---|---|
| `deployment_logs` table too large to query fast | ~500k rows | V1 → V2 |
| Cloud Build quota exceeded per GCP project | >120 build-min/day (free tier) | V1 → V2 |
| Sidekiq connection pool exhausted | >50 concurrent workers | V2 |
| Database connection pool exhausted | >100 concurrent Puma + Sidekiq threads | V2 |
| PollBuildStatusJob floods the queue | >200 concurrent deployments | V2 |
| ActionCable memory per dyno | >500 concurrent WebSocket connections | V3 |
| Single Postgres primary write throughput | >1,000 writes/second sustained | V3 |

---

## Scale Tiers

### V1 — Current (0–10k deployments/month)

Single server, single database, single Redis, Sidekiq on the same host.
No changes needed. Focus on correctness.

```
[Cloud Run: Rails + Sidekiq]
        │
   [Cloud SQL: PostgreSQL]
        │
   [Memorystore: Redis]
```

**Sidekiq config:**
```yaml
concurrency: 10
queues:
  - [deployments, 3]
  - [default, 1]
```

**Database pool:** `RAILS_MAX_THREADS` = 5 (Puma) + 10 (Sidekiq) = 15 connections.

**Log retention:** All rows kept in PostgreSQL indefinitely. Fine at this scale.

---

### V2 — Growth (10k–50k deployments/month)

The log table hits 2M+ rows. Poll jobs stack up. Add these changes in order of impact:

#### 1. Separate Web and Worker processes

Stop running Sidekiq on the web instance. Deploy two Cloud Run services:
- `anchor-web` — Puma only, min 2 instances
- `anchor-worker` — Sidekiq only, min 1 instance, scales to 5

Both share the same Docker image; entrypoint differs.

```dockerfile
# Web
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]

# Worker (override in Cloud Run)
CMD ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
```

Reason: web latency should not be affected by job spikes. Scaling them independently
is cheaper and safer.

#### 2. Split Sidekiq queues by pipeline step

```yaml
# config/sidekiq.yml
concurrency: 20
queues:
  - [deployments_poll, 5]      # many short-lived poll jobs
  - [deployments_build, 3]     # fewer, longer-running build submits
  - [deployments_prepare, 3]   # clone + detect
  - [deployments_deploy, 3]    # final Cloud Run deploy
  - [default, 1]
```

Update `BaseJob` subclasses to use the right queue:
```ruby
class PrepareJob < BaseJob
  queue_as :deployments_prepare
end
class PollBuildStatusJob < BaseJob
  queue_as :deployments_poll
end
```

Reason: `PollBuildStatusJob` runs every 15–60 seconds for every in-flight build.
At 50 concurrent builds, that's ~50 poll jobs/minute. Without a dedicated queue,
they crowd out prepare and deploy steps.

#### 3. Archive deployment logs to GCS

`deployment_logs` hits 5M+ rows at 25k deployments/month. Queries slow down.

Add a nightly archival job:

```ruby
# app/jobs/archive_deployment_logs_job.rb
class ArchiveDeploymentLogsJob < ApplicationJob
  queue_as :default

  # Runs nightly via cron. Moves logs from completed deployments
  # older than 7 days to GCS as newline-delimited JSON.
  def perform
    cutoff = 7.days.ago

    Deployment.terminal.where("finished_at < ?", cutoff)
              .includes(:deployment_logs)
              .find_each(batch_size: 100) do |deployment|
      next unless deployment.deployment_logs.exists?
      upload_to_gcs(deployment)
      deployment.deployment_logs.delete_all
    end
  end

  private

  def upload_to_gcs(deployment)
    lines = deployment.deployment_logs.chronological.map do |log|
      { t: log.logged_at.iso8601, l: log.level, s: log.source, m: log.message }.to_json
    end
    body   = lines.join("\n")
    bucket = ENV.fetch("LOG_ARCHIVE_BUCKET")
    path   = "deployments/#{deployment.project_id}/#{deployment.id}.ndjson"

    storage = Google::Cloud::Storage.new
    storage.bucket(bucket).create_file(StringIO.new(body), path)
  end
end
```

Add `archived_logs_url` column to `deployments`:
```ruby
add_column :deployments, :archived_logs_url, :string
```

Show a "View archived logs" link on the deployment page when logs have been moved.

**Index to add for the archival query:**
```ruby
add_index :deployments, [:status, :finished_at]
```

#### 4. PgBouncer for connection pooling

At 20 Sidekiq threads + 5 Puma threads = 25 active DB connections per instance.
At 3 instances = 75 connections. PostgreSQL handles this fine up to ~200.

Add PgBouncer in transaction mode at V2 to give headroom:
- Use Cloud SQL's built-in connection pooling (enabled in Cloud SQL settings)
- Or deploy pgbouncer as a sidecar

Set in `database.yml`:
```yaml
production:
  pool: <%= ENV.fetch("DB_POOL", 5) %>
  checkout_timeout: 5
```

#### 5. Per-user deployment rate limiting

Prevent a single user from exhausting Cloud Build quota or Sidekiq concurrency.

```ruby
# app/models/project.rb
MAX_CONCURRENT_DEPLOYMENTS = 3

def deployable?
  deployments.in_progress.count < MAX_CONCURRENT_DEPLOYMENTS
end
```

```ruby
# app/controllers/projects_controller.rb
def deploy
  unless @project.deployable?
    return redirect_to @project,
      alert: "A deployment is already in progress. Wait for it to finish."
  end
  # ...
end
```

Add a Sidekiq middleware for global concurrency limiting using Sidekiq's
built-in `Sidekiq::Limiter` (Sidekiq Pro) or a Redis-based semaphore:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add DeploymentConcurrencyMiddleware, limit: 50
  end
end
```

---

### V3 — Scale (50k–100k deployments/month)

#### 1. Read replica for dashboard queries

Dashboard queries (`recent deployments`, `project list`, `log reads`) are
read-heavy. Add a Cloud SQL read replica and route reads there:

```ruby
# config/database.yml
production:
  primary:
    url: <%= ENV["DATABASE_URL"] %>
  replica:
    url: <%= ENV["DATABASE_REPLICA_URL"] %>
    replica: true
```

```ruby
# app/models/deployment.rb
class Deployment < ApplicationRecord
  connects_to database: { writing: :primary, reading: :replica }
end
```

Route read-only actions to the replica:
```ruby
# app/controllers/deployments_controller.rb
def index
  ActiveRecord::Base.connected_to(role: :reading) do
    @deployments = @project.deployments.recent.limit(20)
  end
end
```

#### 2. Partition `deployment_logs` by month

At 100k/month × 200 lines = 20M rows/month. Even with archival, the hot
partition is 5M+ rows. Add PostgreSQL range partitioning:

```ruby
# New migration — replaces the original table
class PartitionDeploymentLogs < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE TABLE deployment_logs_partitioned (
        id          bigserial,
        deployment_id bigint NOT NULL,
        message     text NOT NULL,
        level       varchar NOT NULL DEFAULT 'info',
        source      varchar DEFAULT 'system',
        logged_at   timestamptz NOT NULL,
        created_at  timestamptz NOT NULL,
        updated_at  timestamptz NOT NULL
      ) PARTITION BY RANGE (logged_at);

      CREATE TABLE deployment_logs_2025_01
        PARTITION OF deployment_logs_partitioned
        FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
      -- Add future partitions monthly via a cron job
    SQL
  end
end
```

Use `pg_partman` to automate monthly partition creation and archival.

#### 3. Stream logs to GCS directly (bypass PostgreSQL for hot path)

At 100k/month, writing 20M rows to PostgreSQL is the largest single write load.
Replace the PostgreSQL log store with a two-tier approach:

**Hot logs** (in-flight deployment, <30 min old): Redis list
**Cold logs** (completed deployment): GCS object

```ruby
# app/models/deployment.rb
def append_log(message, level: "info", source: "system")
  entry = { t: Time.current.iso8601(3), l: level, s: source, m: message }

  if in_progress?
    # Write to Redis list — fast, ephemeral
    redis = Redis.new(url: ENV["REDIS_URL"])
    redis.rpush("deployment:#{id}:logs", entry.to_json)
    redis.expire("deployment:#{id}:logs", 2.hours.to_i)
  else
    # Flush Redis buffer to GCS on completion (called from transition_to!)
    flush_logs_to_gcs
  end

  # Turbo Stream broadcast still works the same way
  Turbo::StreamsChannel.broadcast_append_to(
    "deployment_#{id}_logs",
    target:  "deployment_logs",
    partial: "deployments/log_line",
    locals:  { log: OpenStruct.new(entry.merge(logged_at: Time.current)) }
  )
end
```

`deployment_logs` table is dropped in favour of the GCS log objects. The show
page fetches logs from Redis (live) or GCS (historical).

**Note:** This is a significant complexity increase. Only worthwhile at >50k/month.
V1 and V2 keep logs in PostgreSQL.

#### 4. Horizontal Sidekiq scaling

At 100k/month peak, the poll queue needs dedicated workers:

```
anchor-web     — 3 instances × 5 Puma threads
anchor-worker  — 5 instances × 20 Sidekiq threads = 100 concurrent jobs
```

Use Sidekiq's `config/sidekiq.yml` per-worker-type with environment variables:

```yaml
concurrency: <%= ENV.fetch("SIDEKIQ_CONCURRENCY", 20) %>
queues:
  - [deployments_poll, 10]
  - [deployments_build, 4]
  - [deployments_prepare, 4]
  - [deployments_deploy, 4]
  - [default, 1]
```

Scale `anchor-worker` Cloud Run min/max based on queue depth using a custom
Cloud Run scaling metric (Cloud Monitoring → Sidekiq queue size alert).

#### 5. Multi-region (optional at 100k)

If users are globally distributed:

- Deploy `anchor-web` to `us-central1`, `europe-west1`, `asia-east1`
- Single Cloud SQL primary in `us-central1` with cross-region read replicas
- Route web traffic via Cloud Load Balancing by latency
- Sidekiq workers always write to the primary (no replica writes)

---

## Data Model Changes by Tier

```
V1                          V2                          V3
─────────────────────       ─────────────────────       ─────────────────────
deployment_logs             + archived_logs_url          logs in Redis/GCS
(PostgreSQL, all rows)        on deployments             (no PG table)

single deployments          + [status, finished_at]     + monthly partitioning
index on status               composite index

single DB connection        PgBouncer / Cloud SQL        primary + read replica
pool (15 connections)       connection pooler

single Sidekiq queue        4 queues by step             dedicated poll workers
                            per-user concurrency limit   horizontal scaling
```

---

## GCP Quota Management

Cloud Build has hard quotas that affect every user:

| Quota | Free tier | Paid |
|---|---|---|
| Concurrent builds | 1 | 10 (default), requestable higher |
| Build minutes/day | 120 | Billed at $0.003/min |
| Build timeout | 60 min | Up to 60 min |

At 100k deployments/month (avg 5 min build):
```
100,000 × 5 min = 500,000 build-minutes/month
500,000 × $0.003 = $1,500/month in Cloud Build alone
```

**Mitigation:**
1. Each Anchor user brings their own GCP project — Cloud Build runs in their quota, not ours
2. We impose per-user limits to prevent runaway builds:
   ```ruby
   MAX_BUILDS_PER_HOUR_PER_USER = 10
   MAX_CONCURRENT_BUILDS_PER_GCP_PROJECT = 3
   ```
3. Track build minutes per user for potential future billing integration

---

## Queue Depth Monitoring

The most important operational signal is Sidekiq queue depth. A backed-up
`deployments_poll` queue means builds are finishing but deploys are delayed.

```ruby
# config/initializers/sidekiq.rb — add queue depth metric export
Sidekiq.configure_server do |config|
  config.on(:startup) do
    Thread.new do
      loop do
        Sidekiq::Queue.all.each do |q|
          # Export to Cloud Monitoring custom metric
          CloudMonitoring.write_metric(
            "custom.googleapis.com/sidekiq/queue_depth",
            q.size,
            labels: { queue: q.name }
          )
        end
        sleep 30
      end
    end
  end
end
```

Alert thresholds:
- `deployments_poll` > 500 → worker count too low
- `deployments_build` > 100 → Cloud Build API throttled
- Any queue > 1,000 → page on-call

---

## Observability Stack

### V1
- `RAILS_LOG_TO_STDOUT=true` → Cloud Logging
- `lograge` gem for structured single-line request logs
- Sidekiq Web UI at `/sidekiq` (HTTP Basic auth)

### V2 (add)
- Custom Cloud Monitoring metrics: deployment success rate, p50/p95 build duration
- Error rate alert: deployment failure rate > 20% → PagerDuty
- `rack-mini-profiler` in staging for N+1 detection

### V3 (add)
- Distributed tracing via OpenTelemetry → Cloud Trace
- Dashboard in Grafana/Looker: deployments/hour, queue depth trend, framework breakdown
- Synthetic monitoring: deploy a canary repo every 30 minutes, alert if it fails

---

## Security at Scale

| Concern | V1 | V2 | V3 |
|---|---|---|---|
| Tenant isolation | `current_user` scoping in controllers | Automated test suite verifying no cross-user access | Row-level security policies in PostgreSQL |
| GCP credentials | Application Default Credentials | Per-user service account (stored encrypted) | Workload Identity Federation |
| Secret encryption | `attr_encrypted` single key | Key rotation support, per-user derived keys | Cloud KMS envelope encryption |
| Rate limiting | Per-project concurrency check | Rack::Attack on all mutation endpoints | Per-IP + per-user rate limits, CAPTCHA for abuse |
| Audit log | Rails logs | `deployments` table is append-only history | Dedicated `audit_events` table, immutable |

---

## Summary: What to Build Now vs Later

### Build now (V1)

Everything currently in the codebase. It correctly handles the data model,
pipeline, and Hotwire UI. No premature optimisation.

### Build when `deployment_logs` hits 1M rows (V2 trigger)

```
[ ] Log archival job (nightly GCS export + delete_all)
[ ] Separate web and worker Cloud Run services
[ ] Split Sidekiq queues by pipeline step
[ ] Per-user concurrent deployment limit
[ ] Add [status, finished_at] composite index on deployments
```

### Build when Sidekiq queue depth consistently >200 (V3 trigger)

```
[ ] PostgreSQL read replica + connected_to(role: :reading)
[ ] deployment_logs table partitioning or Redis/GCS log store
[ ] Horizontal Sidekiq worker scaling
[ ] Queue depth Cloud Monitoring metric + alert
```

### Never build (not needed at 100k/month)

```
[ ] Microservices
[ ] Message bus (Kafka, Pub/Sub) for internal events
[ ] CQRS / event sourcing
[ ] Separate log ingestion service
[ ] Custom WebSocket server
```

The Rails monolith with PostgreSQL and Sidekiq can reliably handle 100k
deployments/month with the V2 changes. Complexity should only be added
when a specific bottleneck is measured in production — not anticipated in advance.
