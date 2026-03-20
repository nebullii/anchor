module Deployments
  # Step 3 of the deployment pipeline.
  #
  # Polls the Cloud Build status every N seconds using exponential backoff.
  # Re-enqueues itself until the build reaches a terminal state, then either:
  #   - SUCCESS  → enqueues DeployToCloudRunJob
  #   - FAILURE / CANCELLED / TIMEOUT → fails the deployment
  #
  # Max wait: ~30 minutes (matches the Cloud Build timeout).
  #
  class PollBuildStatusJob < BaseJob
    # Cloud Build terminal states
    TERMINAL_STATES  = %w[SUCCESS FAILURE INTERNAL_ERROR TIMEOUT CANCELLED EXPIRED].freeze
    SUCCESS_STATE    = "SUCCESS"

    # Polling schedule (seconds between attempts):
    # attempt 1-3: every 15s, 4-8: every 30s, 9+: every 60s — up to 40 attempts (~28 min)
    MAX_ATTEMPTS = 40

    def perform(deployment_id, build_id, attempt: 1)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "building")

          if attempt > MAX_ATTEMPTS
            raise Deployments::DeploymentError,
                  "Cloud Build timed out after #{MAX_ATTEMPTS} polling attempts (~28 minutes)."
          end

          state = fetch_build_state(deployment, build_id)
          deployment.append_log("Build status: #{state} (poll ##{attempt})", level: "debug")

          if TERMINAL_STATES.include?(state)
            handle_terminal_state(deployment, build_id, state)
          else
            # Not done yet — re-enqueue after a backoff delay.
            delay = backoff_seconds(attempt)
            deployment.append_log("Build running... checking again in #{delay}s.", level: "debug")
            PollBuildStatusJob.set(wait: delay.seconds)
                              .perform_later(deployment_id, build_id, attempt: attempt + 1)
          end
        end
      end
    end

    private

    def fetch_build_state(deployment, build_id)
      cmd = [
        "gcloud builds describe #{Shellwords.escape(build_id)}",
        "--project=#{Shellwords.escape(deployment.project.gcp_project_id)}",
        "--format=value(status)"
      ].join(" ")

      output = run_gcloud!(cmd, deployment: deployment, source: "cloud_build")
      state = output.lines.map(&:strip).reject(&:empty?).last.to_s
      raise Deployments::DeploymentError, "Could not fetch build status" if state.blank?
      state.upcase
    end

    def handle_terminal_state(deployment, build_id, state)
      if state == SUCCESS_STATE
        log_url = build_log_url(build_id, deployment.project.gcp_project_id)
        deployment.update!(cloud_build_log_url: log_url)
        deployment.append_log("Build succeeded.")
        deployment.append_log("Logs: #{log_url}")
        DeployToCloudRunJob.perform_later(deployment.id)
      else
        detail = fetch_failure_detail(deployment, build_id)
        raise Deployments::DeploymentError, "Cloud Build #{state.downcase}: #{detail}"
      end
    end

    def fetch_failure_detail(deployment, build_id)
      cmd = [
        "gcloud builds describe #{Shellwords.escape(build_id)}",
        "--project=#{Shellwords.escape(deployment.project.gcp_project_id)}",
        "--format=value(failureInfo.detail)"
      ].join(" ")
      run_gcloud!(cmd, deployment: deployment, source: "cloud_build").strip
    rescue
      "see Cloud Build logs for details"
    end

    def build_log_url(build_id, gcp_project_id)
      "https://console.cloud.google.com/cloud-build/builds/#{build_id}?project=#{gcp_project_id}"
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
