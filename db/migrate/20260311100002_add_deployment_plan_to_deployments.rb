class AddDeploymentPlanToDeployments < ActiveRecord::Migration[8.1]
  def change
    add_column :deployments, :deployment_plan, :jsonb
    add_column :deployments, :error_category,  :string

    add_index :deployments, :error_category
  end
end
