class CreateProjects < ActiveRecord::Migration[8.0]
  def change
    create_table :projects do |t|
      t.references :user,       null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true

      # Identity
      t.string :name,   null: false
      t.string :slug,   null: false   # URL-safe identifier, e.g. "my-app-prod"

      # GCP deployment config
      t.string :gcp_project_id, null: false
      t.string :gcp_region,     null: false, default: "us-central1"
      t.string :service_name                 # Cloud Run service name (auto-generated if blank)

      # Framework detection (populated after first scan)
      t.string  :framework       # rails | node | python | static | docker
      t.string  :runtime         # ruby3.2 | node20 | python3.11 | nginx
      t.integer :port                        # container port

      # Deployment settings
      t.string :production_branch, default: "main"
      t.boolean :auto_deploy,      default: false, null: false

      # Current state
      t.string :status,      null: false, default: "inactive"
      # inactive | active | error | building
      t.string :latest_url                   # live Cloud Run URL after first success

      t.timestamps
    end

    add_index :projects, :slug,             unique: true
    add_index :projects, :status
    add_index :projects, [:user_id, :name], unique: true
    add_index :projects, :gcp_project_id
    add_index :projects, :service_name
  end
end
