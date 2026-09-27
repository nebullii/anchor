module Deployments
  # Shared behaviour for every step of the deployment pipeline.
  #
  # Error policy:
  #   - Deployments::TransientError (and Providers::TransientError, once the
  #     provider layer exists) is retried by ActiveJob with bounded exponential
  #     backoff. After MAX_ATTEMPTS the deployment is marked failed.
  #   - Deployments::DeploymentError (and any other error) fails the
  #     deployment immediately.
  #   - Deployment::InvalidTransition means the deployment moved on without us
  #     (user cancelled, reaper timed it out) — the job stops quietly.
  #
  class BaseJob < ApplicationJob
    queue_as :deployments

    # Total executions for a transiently-failing step (1 run + 4 retries).
    MAX_ATTEMPTS       = 5
    RETRY_BASE_SECONDS = 15
    RETRY_MAX_SECONDS  = 5.minutes.to_i

    # Retries are handled by ActiveJob (retry_on below), not Sidekiq, so the
    # retry count and the "give up" hook live in one place and work with any
    # queue adapter. Sidekiq retry stays 0 to avoid double retries.
    sidekiq_options retry: 0

    # 15s, 30s, 60s, 120s (+ up to 15% jitter), capped at 5 minutes.
    def self.retry_delay(executions)
      base = [ RETRY_BASE_SECONDS * (2**(executions - 1)), RETRY_MAX_SECONDS ].min
      base + rand(0..(base * 0.15).to_i)
    end

    retry_on Deployments::TransientError,
             attempts: MAX_ATTEMPTS,
             wait:     ->(executions) { retry_delay(executions) } do |job, error|
      job.send(:retries_exhausted!, error)
    end

    private

    # Finds the deployment and yields to the block.
    # Handles record-not-found and unexpected errors uniformly.
    def with_deployment(deployment_id)
      deployment = Deployment.find(deployment_id)
      yield deployment
    rescue Deployment::InvalidTransition => e
      # Cancelled or reaped while this job was running — nothing left to do.
      Rails.logger.info("[#{self.class.name}] Stopping: #{e.message}")
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error("[#{self.class.name}] Deployment #{deployment_id} not found — discarding job.")
    rescue => e
      if transient_error?(e)
        note_transient_error(deployment, e)
        # Normalise provider errors so retry_on sees a single class.
        raise e.is_a?(Deployments::TransientError) ? e : Deployments::TransientError.new(e.message)
      elsif e.is_a?(Deployments::DeploymentError)
        fail_deployment!(deployment, e.message)
      else
        fail_deployment!(deployment, "#{e.class}: #{e.message}")
        raise  # re-raise so Sidekiq shows the job as failed in its UI
      end
    end

    def transient_error?(error)
      return true if error.is_a?(Deployments::TransientError)
      defined?(::Providers::TransientError) && error.is_a?(::Providers::TransientError)
    end

    def note_transient_error(deployment, error)
      Rails.logger.warn(
        "[#{self.class.name}] Transient error on deployment #{deployment&.id} " \
        "(attempt #{executions}/#{MAX_ATTEMPTS}): #{error.message}"
      )
      return unless deployment

      if executions < MAX_ATTEMPTS
        deployment.append_log(
          "Temporary error (attempt #{executions}/#{MAX_ATTEMPTS}): #{error.message} — retrying.",
          level: "warn"
        )
        DeploymentEvent.record(deployment, "retry_scheduled",
                               metadata: { job: self.class.name, attempt: executions, error: error.message })
      end
    rescue => e
      Rails.logger.warn("[#{self.class.name}] Could not record transient error: #{e.message}")
    end

    # Called by retry_on once MAX_ATTEMPTS transient failures have happened.
    def retries_exhausted!(error)
      deployment = Deployment.find_by(id: arguments.first)
      fail_deployment!(
        deployment,
        "#{error.message} (gave up after #{MAX_ATTEMPTS} attempts)"
      )
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

    # Fails the deployment unless it already finished (e.g. was cancelled while
    # this job ran). Only a deployment we actually failed gets hints + AI help.
    def fail_deployment!(deployment, message)
      return unless deployment
      Rails.logger.error("[#{self.class.name}] Deployment #{deployment.id} failed: #{message}")

      category = Deployments::ErrorCategorizer.categorize(message)
      return unless deployment.fail!(message, category: category)

      deployment.append_log(message, level: "error")
      hint = Deployments::ErrorCategorizer.user_hint(category)
      deployment.append_log("Hint: #{hint}", level: "error") if hint.present?
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
        env = Gcp::ShellEnv.with_token(token)
        IO.popen(env, "#{cmd} 2>&1") do |io|
          io.each_line do |raw|
            line = raw.chomp
            output_lines << line
            deployment.append_log(line, source: source) if line.present?
          end
        end
      else
        user.with_gcp_credentials_file do |key_path|
          env = Gcp::ShellEnv.with_key(key_path)
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
