# Personal API tokens used by the `anchor` CLI and the MCP server.
# Only a SHA256 digest of the token is stored — the plaintext is shown once.
class CreateApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string   :name,         null: false
      t.string   :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :api_tokens, :token_digest, unique: true
  end
end
