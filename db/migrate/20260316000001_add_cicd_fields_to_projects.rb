class AddCicdFieldsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :cicd_setup_status, :string, default: "none", null: false
    add_column :projects, :cicd_setup_error,  :text
    add_column :projects, :cicd_committed_at, :datetime
    add_column :projects, :cicd_files,        :jsonb, default: []
  end
end
