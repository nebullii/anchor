class AddAnalysisToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :analysis_status, :string, default: "pending", null: false
    add_column :projects, :analysis_result, :jsonb
    add_column :projects, :analyzed_at,     :datetime

    add_index :projects, :analysis_status
  end
end
