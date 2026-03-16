class DeploymentJob < ApplicationJob
  queue_as :deployments
  sidekiq_options retry: 0

  # Entry point — validates state then hands off to the first pipeline step.
  def perform(deployment_id)
    deployment = Deployment.find(deployment_id)

    unless %w[queued pending].include?(deployment.status)
      Rails.logger.warn("DeploymentJob: #{deployment_id} already #{deployment.status}, skipping.")
      return
    end

    deployment.append_log("Deployment queued — starting pipeline.")
    Deployments::PrepareJob.perform_later(deployment_id)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("DeploymentJob: deployment #{deployment_id} not found.")
  end
end
