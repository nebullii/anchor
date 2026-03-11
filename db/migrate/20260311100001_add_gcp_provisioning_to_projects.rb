class AddGcpProvisioningToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :gcp_provisioned,    :boolean, default: false, null: false
    add_column :projects, :gcp_provisioned_at, :datetime
    add_column :projects, :gcp_provision_error, :text

    add_index :projects, :gcp_provisioned
  end
end
