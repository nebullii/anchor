class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      # GitHub OAuth identity
      t.string :github_id,    null: false
      t.string :github_login, null: false
      t.string :github_token, null: false  # stored encrypted via attr_encrypted

      # Profile
      t.string :name
      t.string :email
      t.string :avatar_url

      # GCP default settings (user can override per project)
      t.string :default_gcp_project_id
      t.string :default_gcp_region, default: "us-central1"

      t.timestamps
    end

    add_index :users, :github_id,    unique: true
    add_index :users, :github_login, unique: true
    add_index :users, :email
  end
end
