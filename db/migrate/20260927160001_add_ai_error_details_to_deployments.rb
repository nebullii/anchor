class AddAiErrorDetailsToDeployments < ActiveRecord::Migration[8.1]
  def change
    # Structured AI explanation: {summary, likely_cause, fix_steps, confidence, category}.
    add_column :deployments, :ai_error_details, :jsonb
  end
end
