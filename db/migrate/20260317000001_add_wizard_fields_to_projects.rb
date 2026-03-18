class AddWizardFieldsToProjects < ActiveRecord::Migration[8.1]
  def change
    # Allow gcp_project_id to be null for draft projects
    change_column_null :projects, :gcp_project_id, true
    change_column_default :projects, :gcp_project_id, nil

    add_column :projects, :draft, :boolean, default: false, null: false
    add_column :projects, :target_platform, :string, default: "gcp", null: false
  end
end
