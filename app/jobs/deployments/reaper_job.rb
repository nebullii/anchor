module Deployments
  # Fails deployments that have been stuck in an in-progress status for too long
  # (worker crashed mid-step, job lost, build hung, ...). Without this, a lost
  # job leaves the deployment — and the project's one-active-deployment slot —
  # blocked forever.
  #
  # Scheduling: runs every INTERVAL. Each run schedules the next one, and a
  # Redis "next run is scheduled" marker (SET NX) guarantees there is only ever
  # one pending chain, no matter how many Sidekiq processes boot and call
  # ReaperJob.ensure_scheduled. A second Redis lock stops two runs overlapping.
  #
  class ReaperJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: 0

    INTERVAL = 5.minutes

    # How long a deployment may sit in each in-progress status before it is
    # considered stuck. Generous on purpose: this is a safety net, not a timer.
    TIMEOUTS = {
      "queued"       => 15.minutes,
      "pending"      => 15.minutes,
      "analyzing"    => 20.minutes,
      "cloning"      => 20.minutes,
      "detecting"    => 20.minutes,
      "building"     => 45.minutes,
      "deploying"    => 20.minutes,
      "health_check" => 20.minutes
    }.freeze

    # A health check logs every attempt (at most ~30s apart). If a deployment
    # in health_check has been silent this long, the worker lost the job (hard
    # crash / OOM) — possibly mid-promotion. The step is idempotent, so it is
    # resumed once before the deployment is ever failed.
    RESUME_AFTER = 3.minutes

    RUN_LOCK_KEY  = "anchor:deployments:reaper:running".freeze
    SCHEDULE_KEY  = "anchor:deployments:reaper:scheduled".freeze
    RUN_LOCK_TTL  = 4.minutes.to_i
    SCHEDULE_TTL  = (INTERVAL * 2).to_i

    # Called on Sidekiq server startup. Runs a reap soon and makes sure the
    # recurring chain exists (a no-op if another process already owns it).
    def self.ensure_scheduled
      perform_later
    end

    # Enqueues the next run unless one is already pending.
    def self.schedule_next
      return unless redis_set_nx(SCHEDULE_KEY, Time.current.to_i.to_s, SCHEDULE_TTL)
      set(wait: INTERVAL).perform_later(true)
    end

    # scheduled: true when this run is the recurring chain's own job.
    def perform(scheduled = false)
      # Our marker is consumed — clear it so we can schedule the successor.
      self.class.redis_del(SCHEDULE_KEY) if scheduled

      if self.class.redis_set_nx(RUN_LOCK_KEY, job_id.to_s, RUN_LOCK_TTL)
        begin
          reap!
        ensure
          self.class.redis_del(RUN_LOCK_KEY)
        end
      else
        Rails.logger.info("[ReaperJob] Another reaper run is in progress — skipping.")
      end
    ensure
      self.class.schedule_next
    end

    # Resumes lost health checks, then fails every stuck deployment. Returns
    # the deployments that were reaped (failed).
    def reap!(now: Time.current)
      resume_lost_health_checks!(now: now)

      reaped = []
      TIMEOUTS.each do |status, timeout|
        cutoff = now - timeout
        Deployment.where(status: status)
                  .where("COALESCE(status_changed_at, updated_at) < ?", cutoff)
                  .find_each do |deployment|
          reaped << deployment if reap_one(deployment, status, timeout, cutoff)
        end
      end
      Rails.logger.info("[ReaperJob] Reaped #{reaped.size} stuck deployment(s).") if reaped.any?
      reaped
    end

    # Re-enqueues HealthCheckJob (once per deployment) for health checks whose
    # job was lost. Returns the resumed deployments.
    def resume_lost_health_checks!(now: Time.current)
      cutoff = now - RESUME_AFTER
      Deployment.where(status: "health_check").where.not(revision_url: [ nil, "" ]).find_each.select do |deployment|
        last_activity = [ deployment.deployment_logs.maximum(:logged_at),
                          deployment.status_changed_at || deployment.updated_at ].compact.max
        next false if last_activity > cutoff
        next false if deployment.deployment_events.for_type("resumed").exists?

        DeploymentEvent.record(deployment, "resumed", metadata: { step: "health_check" })
        deployment.append_log("The worker lost this step (it may have restarted). Resuming the health check.",
                              level: "warn")
        HealthCheckJob.perform_later(deployment.id)
        true
      end
    rescue => e
      Rails.logger.error("[ReaperJob] Could not resume health checks: #{e.class}: #{e.message}")
      []
    end

    private

    def reap_one(deployment, status, timeout, cutoff)
      minutes = (timeout / 60).to_i
      message = "Deployment timed out: it was stuck in '#{status}' for more than #{minutes} minutes. " \
                "The worker may have restarted or the step hung. Please deploy again."

      failed = false
      deployment.with_lock do
        # Re-check under the lock — the pipeline may have progressed meanwhile.
        still_stuck = deployment.status == status &&
                      (deployment.status_changed_at || deployment.updated_at) < cutoff
        next unless still_stuck

        failed = deployment.fail!(message, category: "timeout")
      end
      return false unless failed

      deployment.append_log(message, level: "error")
      DeploymentEvent.record(deployment, "timed_out", metadata: { status: status, timeout_minutes: minutes })
      stop_remote_build(deployment) if status == "building"
      true
    rescue => e
      Rails.logger.error("[ReaperJob] Could not reap deployment #{deployment.id}: #{e.class}: #{e.message}")
      false
    end

    # Best effort: don't leave a hung build burning the user's cloud minutes.
    def stop_remote_build(deployment)
      return unless defined?(::Providers) && ::Providers.respond_to?(:for)
      ::Providers.for(deployment.project).cancel_build!(deployment)
    rescue => e
      Rails.logger.warn("[ReaperJob] cancel_build! failed for deployment #{deployment.id}: #{e.message}")
    end

    class << self
      # Redis helpers — isolated so specs can stub them without a Redis server.
      # A Redis outage must not take the reaper down: set_nx returns false
      # (skip this run) and del is ignored.
      def redis_set_nx(key, value, ttl)
        Sidekiq.redis { |conn| conn.call("SET", key, value, "NX", "EX", ttl) } == "OK"
      rescue => e
        Rails.logger.warn("[ReaperJob] Redis unavailable (#{e.class}: #{e.message})")
        false
      end

      def redis_del(key)
        Sidekiq.redis { |conn| conn.call("DEL", key) }
      rescue => e
        Rails.logger.warn("[ReaperJob] Redis unavailable (#{e.class}: #{e.message})")
        nil
      end
    end
  end
end
