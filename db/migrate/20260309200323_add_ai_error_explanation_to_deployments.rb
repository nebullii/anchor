class AddAiErrorExplanationToDeployments < ActiveRecord::Migration[8.1]
  def change
    add_column :deployments, :ai_error_explanation, :text
  end
end
