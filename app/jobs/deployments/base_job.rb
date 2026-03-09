module Deployments
  class BaseJob < ApplicationJob
    queue_as :deployments

    # Deployment jobs must not auto-retry — a failed step leaves the deployment
    # in a terminal "failed" state. The user re-triggers from the UI.
    sidekiq_options retry: 0

    private

    # Finds the deployment and yields to the block.
    # Handles record-not-found and unexpected errors uniformly.
    def with_deployment(deployment_id)
      deployment = Deployment.find(deployment_id)
      yield deployment
    rescue Deployments::DeploymentError => e
      fail_deployment!(deployment, e.message)
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error("[#{self.class.name}] Deployment #{deployment_id} not found — discarding job.")
    rescue => e
      fail_deployment!(deployment, "#{e.class}: #{e.message}")
      raise  # re-raise so Sidekiq marks the job as failed in its UI
    end

    # Guards against running a step when the deployment is already in a terminal
    # state (e.g. a duplicate job fired, or user cancelled).
    def guard_status!(deployment, *expected_statuses)
      return if expected_statuses.map(&:to_s).include?(deployment.status)

      Rails.logger.warn(
        "[#{self.class.name}] Deployment #{deployment.id} is '#{deployment.status}', " \
        "expected #{expected_statuses.join(' or ')} — skipping."
      )
      throw :skip
    end

    def fail_deployment!(deployment, message)
      return unless deployment
      Rails.logger.error("[#{self.class.name}] Deployment #{deployment.id} failed: #{message}")
      deployment.update!(error_message: message)
      deployment.append_log(message, level: "error")
      deployment.transition_to!("failed")
    end

    # Returns env vars to inject into every gcloud command so it authenticates
    # as the project owner rather than the machine's default credentials.
    def gcloud_env(deployment)
      user = deployment.project.user
      unless user.google_connected?
        raise Deployments::DeploymentError,
              "Google Cloud not connected. Please connect your Google account in settings."
      end
      token = user.fresh_google_access_token
      { "CLOUDSDK_AUTH_ACCESS_TOKEN" => token, "CLOUDSDK_CORE_DISABLE_PROMPTS" => "1" }
    end

    # Runs a shell command with gcloud auth env injected.
    def run_gcloud!(cmd, deployment:, source: "system")
      env = gcloud_env(deployment)
      output_lines = []

      IO.popen(env, "#{cmd} 2>&1") do |io|
        io.each_line do |raw|
          line = raw.chomp
          output_lines << line
          deployment.append_log(line, source: source) if line.present?
        end
      end

      unless $?.success?
        raise Deployments::DeploymentError,
              "Command failed (exit #{$?.exitstatus}):\n#{output_lines.last(10).join("\n")}"
      end

      output_lines.join("\n")
    end
  end
end
