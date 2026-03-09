class CreateRepositories < ActiveRecord::Migration[8.0]
  def change
    create_table :repositories do |t|
      t.references :user, null: false, foreign_key: true

      # GitHub identifiers
      t.string  :github_id,       null: false   # GitHub's internal numeric repo ID
      t.string  :name,            null: false   # "my-app"
      t.string  :full_name,       null: false   # "owner/my-app"
      t.string  :owner_login,     null: false   # "owner"

      # Metadata
      t.text    :description
      t.string  :default_branch,  default: "main"
      t.string  :clone_url,       null: false
      t.string  :html_url,        null: false
      t.boolean :private,         default: false, null: false
      t.string  :language                         # primary language GitHub detected
      t.integer :size_kb                          # repo size in KB from GitHub

      # Sync tracking
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :repositories, :github_id,    unique: true
    add_index :repositories, :full_name,    unique: true
    add_index :repositories, :owner_login
    add_index :repositories, :last_synced_at
  end
end
