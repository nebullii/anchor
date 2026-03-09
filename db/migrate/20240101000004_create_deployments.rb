class CreateDeployments < ActiveRecord::Migration[8.0]
  def change
    create_table :deployments do |t|
      t.references :project, null: false, foreign_key: true

      # Pipeline status
      t.string :status, null: false, default: "pending"
      # pending | cloning | detecting | building | deploying | success | failed | cancelled

      # Git context
      t.string :commit_sha
      t.text   :commit_message
      t.string :commit_author
      t.string :branch

      # Trigger info
      t.string :triggered_by, default: "manual"
      # manual | webhook | api

      # Cloud Build
      t.string :cloud_build_id
      t.string :cloud_build_log_url

      # Container image
      t.string :image_url         # full Artifact Registry image URL with digest

      # Result
      t.string :service_url       # Cloud Run URL on success
      t.text   :error_message     # populated on failure

      # Timing
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :deployments, :status
    add_index :deployments, :cloud_build_id
    add_index :deployments, :commit_sha
    add_index :deployments, :triggered_by
    add_index :deployments, [:project_id, :status]
    add_index :deployments, :created_at
  end
end
