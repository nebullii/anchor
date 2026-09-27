module Deployments
  # Runs after a deployment fails to generate an AI-powered explanation
  # of what went wrong and how to fix it.
  #
  # Enqueued by BaseJob#fail_deployment! when the deployment transitions
  # to "failed". Stores the human-readable explanation on the deployment
  # (ai_error_explanation), plus the structured + raw model output in
  # ai_error_details when that jsonb column exists, and broadcasts a
  # Turbo Stream update to refresh the outcome panel.
  #
  class ExplainErrorJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: 1

    def perform(deployment_id)
      deployment = Deployment.find_by(id: deployment_id)
      return unless deployment&.failed?

      result = Ai::ErrorExplainer.new(deployment).call
      return if result.nil?

      text = result.to_text
      return if text.blank?

      attrs = { ai_error_explanation: text }
      attrs[:ai_error_details] = result.to_h if Deployment.column_names.include?("ai_error_details")
      deployment.update_columns(attrs)

      Turbo::StreamsChannel.broadcast_update_to(
        "deployment_#{deployment.id}",
        target:  "deployment_outcome",
        partial: "deployments/outcome",
        locals:  { deployment: deployment }
      )
    end
  end
end
