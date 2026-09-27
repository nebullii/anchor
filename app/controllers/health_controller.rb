require "sidekiq/api"

# Operability endpoints for Anchor itself. Unauthenticated, JSON only.
#
#   GET /healthz — liveness: the Ruby process is up and serving requests.
#                  Touches no dependencies, so a DB/Redis blip never gets the
#                  container killed. Use for Cloud Run liveness/startup probes.
#
#   GET /readyz  — readiness/dependency check for uptime monitoring & alerting:
#                    database  SELECT 1
#                    redis     PING
#                    sidekiq   ≥1 worker process with a fresh heartbeat
#                    queues    oldest job latency ≤ READYZ_MAX_QUEUE_LATENCY (s)
#                  200 when all pass, 503 otherwise. Do NOT wire this as the
#                  web container's liveness probe — a worker outage would then
#                  take the UI down too.
#
# Inherits from ActionController::API so it skips login, CSRF, sessions and
# the browser-version gate on ApplicationController.
class HealthController < ActionController::API
  DEFAULT_MAX_QUEUE_LATENCY = 300 # seconds
  HEARTBEAT_MAX_AGE         = 60  # seconds; Sidekiq beats every ~10s

  def live
    render json: { status: "ok", time: Time.current.iso8601 }
  end

  def ready
    checks = {
      database: run_check { check_database },
      redis:    run_check { check_redis },
      sidekiq:  run_check { check_sidekiq_processes },
      queues:   run_check { check_queue_latency }
    }
    healthy = checks.values.all? { |c| c[:ok] }

    render json: { status: healthy ? "ok" : "fail", checks: checks, time: Time.current.iso8601 },
           status: healthy ? :ok : :service_unavailable
  end

  private

  # Each check returns a Hash of details or raises; exceptions become a failed
  # check with the error class (messages can contain hostnames/credentials).
  def run_check
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    detail  = yield
    { ok: detail.delete(:ok) != false }.merge(detail).merge(ms: elapsed_ms(started))
  rescue => e
    Rails.logger.warn("[HealthController] readiness check failed: #{e.class}: #{e.message}")
    { ok: false, error: e.class.name, ms: elapsed_ms(started) }
  end

  def check_database
    ActiveRecord::Base.connection.select_value("SELECT 1")
    {}
  end

  def check_redis
    Sidekiq.redis { |conn| conn.call("PING") }
    {}
  end

  def check_sidekiq_processes
    now   = Time.now.to_f
    fresh = Sidekiq::ProcessSet.new.count { |p| now - p["beat"].to_f <= HEARTBEAT_MAX_AGE }
    { ok: fresh.positive?, processes: fresh }
  end

  def check_queue_latency
    max       = Integer(ENV.fetch("READYZ_MAX_QUEUE_LATENCY", DEFAULT_MAX_QUEUE_LATENCY))
    latencies = Sidekiq::Queue.all.to_h { |q| [ q.name, q.latency.round(1) ] }
    worst     = latencies.values.max || 0
    { ok: worst <= max, max_latency: worst, threshold: max, latencies: latencies }
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  end
end
