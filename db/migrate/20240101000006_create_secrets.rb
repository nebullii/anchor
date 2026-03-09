class CreateSecrets < ActiveRecord::Migration[8.0]
  def change
    create_table :secrets do |t|
      t.references :project, null: false, foreign_key: true

      t.string :key,   null: false
      # Encrypted columns — attr_encrypted stores ciphertext + IV as separate columns
      # encrypted_value and encrypted_value_iv are the actual DB columns
      t.text   :encrypted_value,    null: false
      t.string :encrypted_value_iv, null: false

      t.timestamps
    end

    # A project cannot have two secrets with the same key
    add_index :secrets, [:project_id, :key], unique: true
  end
end
