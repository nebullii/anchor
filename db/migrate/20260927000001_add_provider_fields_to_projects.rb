# Provider abstraction: which backend a project deploys to, plus per-project
# runtime settings that used to be hardcoded in the Cloud Run deploy command.
class AddProviderFieldsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :provider,          :string,  null: false, default: "gcp_cloud_run"
    add_column :projects, :public_access,     :boolean, null: false, default: true
    add_column :projects, :memory,            :string,  null: false, default: "512Mi"
    add_column :projects, :health_check_path, :string,  null: false, default: "/"
    add_index  :projects, :provider
  end
end
