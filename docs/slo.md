# Anchor SLOs

Service level objectives for the deployment path. They measure what users feel:
does my deploy work, how fast is it live, and how fast can I undo it.
Window: rolling 28 days unless noted. Operational procedures are in [runbook.md](runbook.md).

## SLIs and objectives

| SLI | Definition | Objective |
|---|---|---|
| **Deploy success rate** (platform) | `running` ÷ (`running` + `failed` where `error_category` is a platform fault: `unknown`, `auth_error` from Anchor's own credentials, `quota_exceeded`, provider/transient errors) | **≥ 99%** |
| **Deploy success rate** (overall) | `running` ÷ all terminal non-cancelled deploys | Tracked, no objective (user code failures are expected) |
| **Time to live URL** | `finished_at − created_at` for deploys ending `running` | **p50 ≤ 4 min, p95 ≤ 10 min** |
| **Rollback time** | `finished_at − created_at` for `triggered_by = "rollback"` ending `running` | **p50 ≤ 30 s, p95 ≤ 2 min** |
| **Rollback success rate** | rollback deploys `running` ÷ all terminal rollback deploys | **≥ 99.5%** |
| **Bad release exposure** | deploys that reached `running` without passing the health check | **0** (hard invariant: enforced by `HealthCheckJob`) |
| **Control plane availability** | `/readyz` 200 ratio from an external prober, 1-min interval | **≥ 99.5%** |

`failed` deploys with `error_category = "health_check"` count **against** the user's app,
not the platform, as long as the previous revision kept serving. That is the system
working as designed.

## Queries

```ruby
window = 28.days.ago..
terminal = Deployment.where(created_at: window).where.not(status: "cancelled")

# Deploy success rate (overall)
ok  = terminal.where(status: "running").where.not(triggered_by: "rollback").count
all = terminal.where(status: %w[running failed]).where.not(triggered_by: "rollback").count
ok.fdiv(all)

# Time to live URL, p50 / p95 (seconds)
Deployment.where(created_at: window, status: "running").where.not(triggered_by: "rollback")
  .pick(Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM finished_at - created_at))"),
        Arel.sql("percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM finished_at - created_at))"))

# Rollback time, p50 / p95 (seconds)
Deployment.where(created_at: window, status: "running", triggered_by: "rollback")
  .pick(Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM finished_at - created_at))"),
        Arel.sql("percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM finished_at - created_at))"))
```

When a newer deployment goes live, the previous one is relabelled `superseded`; when a rollback replaces it, `rolled_back`. Exactly one deployment per project is `running` at a time.
For historical success rates, count `rolled_back` as success too.

## Alerting (burn-rate, suggested)

| Alert | Condition | Action |
|---|---|---|
| Page | `/readyz` failing for 5 consecutive minutes | runbook §4 / §5 |
| Page | Platform deploy failures > 5% over 1 h (≥ 10 deploys) | Check provider errors, runbook §1 |
| Ticket | `queues.max_latency` > 120 s for 15 min | Scale worker concurrency / instances |
| Ticket | Time-to-live p95 > 10 min over 24 h | Check Cloud Build duration, health check budget |
| Ticket | Any rollback `failed` | runbook §3. Traffic was unchanged, but the undo path is broken. |

## Error budget policy

When the platform deploy success SLO is exhausted in the window, freeze feature work on the
deploy pipeline and spend engineering time on reliability until the rate recovers.
