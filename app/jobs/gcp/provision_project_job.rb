module Gcp
  # Enables GCP APIs and creates the Artifact Registry repository for a project
  # before the first deployment. Runs asynchronously so the user is not blocked.
  #
  # The job marks the project as `gcp_provisioned: true` on success, or stores
  # the error in `gcp_provision_error` on failure so the UI can surface it.
  class ProvisionProjectJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: 2

    def perform(project_id)
      project = Project.find(project_id)
      user    = project.user

      # Skip if user has no GCP credentials configured
      unless user.google_connected?
        Rails.logger.warn("[ProvisionProjectJob] User #{user.id} has no GCP credentials. Skipping provisioning.")
        return
      end

      return if project.gcp_provisioned?

      steps = []

      Gcp::ApiEnabler.new(user, project.gcp_project_id).call do |line|
        steps << line
        Rails.logger.info("[ProvisionProjectJob] #{line}")
      end

      Gcp::ArtifactRegistryProvisioner.new(
        user,
        project.gcp_project_id,
        project.gcp_region
      ).call do |line|
        steps << line
        Rails.logger.info("[ProvisionProjectJob] #{line}")
      end

      project.update!(
        gcp_provisioned:    true,
        gcp_provisioned_at: Time.current,
        gcp_provision_error: nil
      )

      Rails.logger.info("[ProvisionProjectJob] Project #{project.id} provisioned successfully.")
    rescue Gcp::ProvisioningError, ActiveRecord::RecordNotFound => e
      project&.update_columns(gcp_provision_error: e.message)
      Rails.logger.error("[ProvisionProjectJob] Provisioning failed for project #{project_id}: #{e.message}")
      raise  # allow sidekiq retry
    end
  end
end
