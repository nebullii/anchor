module Deployments
  # Step 5 of the deployment pipeline: gate traffic on a passing health check.
  #
  # Each run performs ONE probe of the new revision's URL + the project's
  # health_check_path. On failure it re-enqueues itself with a backoff delay
  # (`set(wait:)`) until either the attempt limit or the time budget is spent,
  # so no Sidekiq thread is ever parked in `sleep` waiting for a cold start.
  #
  #   pass → provider.promote! → service_url/latest_url updated → running
  #   fail → NOT promoted, revision deleted (best effort) → failed/health_check
  #
  # See Deployments::HealthChecker for what counts as healthy.
  #
  class HealthCheckJob < BaseJob
    FAILURE_CATEGORY = "health_check".freeze

    # attempt:    1-based attempt number
    # started_at: epoch seconds of the first attempt (for the time budget)
    def perform(deployment_id, attempt = 1, started_at = nil)
      started_at ||= Time.current.to_f

      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          if deployment.status == "cancelled"
            discard_revision(deployment, "Deployment was cancelled during health check")
            throw :skip
          end
          guard_status!(deployment, "health_check")

          project = deployment.project
          result  = probe(deployment, project)
          label   = "Health check #{attempt}/#{HealthChecker.max_attempts}"

          if result.healthy?
            deployment.append_log("#{label} passed (#{result.detail}).")
            promote!(deployment, project)
          elsif retry_allowed?(attempt, started_at)
            delay = HealthChecker.backoff_for(attempt)
            deployment.append_log("#{label} failed (#{result.detail}); retrying in #{delay}s.", level: "warn")
            HealthCheckJob.set(wait: delay.seconds).perform_later(deployment.id, attempt + 1, started_at)
          else
            deployment.append_log("#{label} failed (#{result.detail}).", level: "warn")
            fail_health_check!(deployment, attempt, started_at, result)
          end
        end
      end
    end

    private

    def probe(deployment, project)
      provider = Providers.for(project)
      # Providers may supply auth headers (e.g. an identity token for private
      # Cloud Run services). Optional — not part of the base contract.
      headers = provider.respond_to?(:health_check_headers) ? provider.health_check_headers(deployment) : {}
      path    = project.try(:health_check_path).presence || "/"

      url     = provider.respond_to?(:health_check_url) ? provider.health_check_url(deployment) : deployment.revision_url

      HealthChecker.new(url, path: path, headers: headers).probe
    end

    def retry_allowed?(attempt, started_at)
      return false if attempt >= HealthChecker.max_attempts

      elapsed = Time.current.to_f - started_at.to_f
      elapsed + HealthChecker.backoff_for(attempt) <= HealthChecker.budget_seconds
    end

    def promote!(deployment, project)
      provider = Providers.for(project)
      deployment.append_log("Shifting 100% of traffic to #{deployment.revision_name}...")

      service_url = begin
        provider.promote!(deployment, log: ->(line) { deployment.append_log(line.to_s, source: "system") if line.present? })
      rescue Providers::TransientError => e
        raise Deployments::TransientError, e.message
      rescue Providers::Error => e
        raise Deployments::DeploymentError, "Promotion failed: #{e.message}"
      end

      service_url = service_url.presence || deployment.service_url.presence || project.latest_url
      deployment.update!(service_url: service_url)
      project.update!(latest_url: service_url) if service_url.present?

      deployment.append_log("Deployment complete.")
      deployment.append_log("Live at: #{service_url}") if service_url.present?
      deployment.transition_to!("running")
      deployment.supersede_previous!
    end

    def fail_health_check!(deployment, attempt, started_at, result)
      elapsed = (Time.current.to_f - started_at.to_f).round
      message = "Health check failed after #{attempt} attempt(s) over #{elapsed}s " \
                "(last result: #{result.detail}). The new revision was NOT promoted; " \
                "the previous revision is still serving traffic."

      discard_revision(deployment, "Removing unhealthy revision")

      Rails.logger.error("[#{self.class.name}] Deployment #{deployment.id} failed: #{message}")
      deployment.update!(error_message: message, error_category: FAILURE_CATEGORY)
      deployment.append_log(message, level: "error")
      deployment.append_log(
        "Hint: make sure the app listens on $PORT and #{deployment.project.try(:health_check_path).presence || '/'} " \
        "responds with a status below 500 within a few seconds of boot.",
        level: "error"
      )
      deployment.transition_to!("failed")
      ExplainErrorJob.perform_later(deployment.id)
    end

    # Best effort — a leftover revision without traffic is harmless, so a
    # cleanup failure must never mask the real outcome.
    def discard_revision(deployment, reason)
      return if deployment.revision_name.blank?

      deployment.append_log("#{reason}: deleting revision #{deployment.revision_name}.", level: "warn")
      Providers.for(deployment.project).delete_revision!(deployment)
    rescue => e
      Rails.logger.warn("[#{self.class.name}] delete_revision! failed for deployment #{deployment.id}: #{e.message}")
      deployment.append_log("Could not delete revision #{deployment.revision_name}: #{e.message}", level: "warn")
    end
  end
end
