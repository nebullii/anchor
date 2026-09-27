module Gcp
  # Enables GCP APIs and creates the Artifact Registry repository for a project
  # before the first deployment. Runs asynchronously so the user is not blocked.
  #
  # Delegates to Providers::GcpCloudRun#provision!, which marks the project
  # `gcp_provisioned: true` on success. Failures are stored in
  # `gcp_provision_error` so the UI can surface them; only transient failures
  # (rate limits, 5xx, network) are retried by Sidekiq.
  class ProvisionProjectJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: 2

    def perform(project_id)
      project = Project.find_by(id: project_id)
      return Rails.logger.warn("[ProvisionProjectJob] Project #{project_id} not found — skipping.") unless project

      # Only Cloud Run projects need cloud provisioning.
      return unless project.gcp_cloud_run?
      return if project.gcp_provisioned?

      unless project.user.google_connected?
        Rails.logger.warn("[ProvisionProjectJob] User #{project.user_id} has no GCP credentials. Skipping provisioning.")
        return
      end

      Providers.for(project).provision!(log: ->(line) { Rails.logger.info("[ProvisionProjectJob] #{line}") })
      Rails.logger.info("[ProvisionProjectJob] Project #{project.id} provisioned successfully.")
    rescue Providers::TransientError => e
      project&.update_columns(gcp_provision_error: e.message)
      Rails.logger.warn("[ProvisionProjectJob] Transient failure for project #{project_id}: #{e.message}")
      raise  # allow sidekiq retry
    rescue Providers::Error => e
      project&.update_columns(gcp_provision_error: e.message)
      Rails.logger.error("[ProvisionProjectJob] Provisioning failed for project #{project_id}: #{e.message}")
    end
  end
end
