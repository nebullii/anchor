module Deployments
  # Step 2 of the deployment pipeline.
  #
  # Asks the project's provider for the status of deployment.build_ref and
  # re-enqueues itself with backoff until the build reaches a terminal state:
  #   - success → enqueues DeployToCloudRunJob (the release step)
  #   - failure → fails the deployment with the provider's detail
  #
  # Stateless: needs only the deployment ID, so any worker can run it.
  # Synchronous providers (LocalDocker) answer :success on the first poll.
  #
  # Max wait: ~28 minutes (matches the Cloud Build timeout).
  #
  class PollBuildStatusJob < BaseJob
    # Polling schedule (seconds between attempts):
    # attempt 1-3: every 15s, 4-8: every 30s, 9+: every 60s — up to 40 attempts (~28 min)
    MAX_ATTEMPTS = 40

    # The second positional argument is accepted (only to backfill build_ref) so jobs
    # enqueued by the previous pipeline — perform(id, build_id, attempt:) —
    # still deserialize after a deploy.
    def perform(deployment_id, legacy_build_id = nil, attempt: 1)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "building")

          if attempt > MAX_ATTEMPTS
            raise Deployments::DeploymentError,
                  "Build timed out after #{MAX_ATTEMPTS} polling attempts (~28 minutes)."
          end

          # Backfill build_ref for deployments started by the old pipeline.
          if deployment.build_ref.blank? && legacy_build_id.present?
            deployment.update!(build_ref: legacy_build_id)
          end

          status = Providers.translate_errors { Providers.for(deployment.project).build_status(deployment) }
          deployment.append_log("Build status: #{status.detail || status.state} (poll ##{attempt})", level: "debug")

          case status.state
          when :success then handle_success(deployment, status)
          when :failure then raise Deployments::DeploymentError, status.detail.presence || "Build failed."
          else               reschedule(deployment, attempt)
          end
        end
      end
    end

    private

    def handle_success(deployment, status)
      deployment.update!(cloud_build_log_url: status.log_url) if status.log_url.present?
      deployment.append_log("Build succeeded.")
      deployment.append_log("Logs: #{status.log_url}") if status.log_url.present?
      DeployToCloudRunJob.perform_later(deployment.id)
    end

    def reschedule(deployment, attempt)
      delay = backoff_seconds(attempt)
      deployment.append_log("Build running... checking again in #{delay}s.", level: "debug")
      PollBuildStatusJob.set(wait: delay.seconds).perform_later(deployment.id, attempt: attempt + 1)
    end

    # Exponential backoff capped at 60 seconds.
    # Attempts 1-3 → 15s, 4-8 → 30s, 9+ → 60s
    def backoff_seconds(attempt)
      if attempt <= 3
        15
      elsif attempt <= 8
        30
      else
        60
      end
    end
  end
end
