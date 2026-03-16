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
    rescue Deployments::TransientError => e
      # Transient errors are logged but NOT marked as failed — re-raise for Sidekiq retry.
      Rails.logger.warn("[#{self.class.name}] Transient error on deployment #{deployment_id}: #{e.message}")
      raise
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
      category = Deployments::ErrorCategorizer.categorize(message)
      deployment.update!(error_message: message, error_category: category)
      deployment.append_log(message, level: "error")
      hint = Deployments::ErrorCategorizer.user_hint(category)
      deployment.append_log("Hint: #{hint}", level: "error") if hint.present?
      deployment.transition_to!("failed")
      ExplainErrorJob.perform_later(deployment.id)
    end

    # Runs a gcloud command authenticated via OAuth token (preferred) or service account key.
    def run_gcloud!(cmd, deployment:, source: "system")
      user = deployment.project.user

      unless user.google_connected?
        raise Deployments::DeploymentError,
              "Google Cloud not connected. Connect via OAuth or add a service account key in Settings."
      end

      output_lines = []

      if user.google_oauth_connected?
        token = user.fresh_google_token!
        env = {
          "CLOUDSDK_AUTH_ACCESS_TOKEN"    => token,
          "CLOUDSDK_CORE_DISABLE_PROMPTS" => "1"
        }
        IO.popen(env, "#{cmd} 2>&1") do |io|
          io.each_line do |raw|
            line = raw.chomp
            output_lines << line
            deployment.append_log(line, source: source) if line.present?
          end
        end
      else
        user.with_gcp_credentials_file do |key_path|
          env = {
            "GOOGLE_APPLICATION_CREDENTIALS"         => key_path,
            "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" => key_path,
            "CLOUDSDK_CORE_DISABLE_PROMPTS"          => "1"
          }
          IO.popen(env, "#{cmd} 2>&1") do |io|
            io.each_line do |raw|
              line = raw.chomp
              output_lines << line
              deployment.append_log(line, source: source) if line.present?
            end
          end
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
