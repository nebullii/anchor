class AddGoogleAuthToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :google_email,                    :string
    add_column :users, :encrypted_google_access_token,   :text
    add_column :users, :encrypted_google_access_token_iv, :string
    add_column :users, :encrypted_google_refresh_token,   :text
    add_column :users, :encrypted_google_refresh_token_iv, :string
    add_column :users, :google_token_expires_at,          :datetime
  end
end
