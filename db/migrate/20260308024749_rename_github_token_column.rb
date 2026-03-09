class RenameGithubTokenColumn < ActiveRecord::Migration[8.1]
  def change
    rename_column :users, :github_token, :encrypted_github_token
    add_column :users, :encrypted_github_token_iv, :string
  end
end
