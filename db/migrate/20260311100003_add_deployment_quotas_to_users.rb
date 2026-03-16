class AddDeploymentQuotasToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :deployments_today,    :integer, default: 0, null: false
    add_column :users, :deployments_this_month, :integer, default: 0, null: false
    add_column :users, :quota_reset_at,       :datetime
  end
end
