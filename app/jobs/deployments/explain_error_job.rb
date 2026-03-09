module Deployments
  # Runs after a deployment fails to generate an AI-powered explanation
  # of what went wrong and how to fix it.
  #
  # Enqueued by BaseJob#fail_deployment! when the deployment transitions
  # to "failed". Stores the result on the deployment record and broadcasts
  # a Turbo Stream update to refresh the outcome panel.
  #
  class ExplainErrorJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: 1

    def perform(deployment_id)
      deployment = Deployment.find_by(id: deployment_id)
      return unless deployment&.failed?

      explanation = Ai::ErrorExplainer.new(deployment).call
      return unless explanation.present?

      deployment.update_columns(ai_error_explanation: explanation)

      Turbo::StreamsChannel.broadcast_replace_to(
        "deployment_#{deployment.id}",
        target:  "deployment_outcome",
        partial: "deployments/outcome",
        locals:  { deployment: deployment }
      )
    end
  end
end
