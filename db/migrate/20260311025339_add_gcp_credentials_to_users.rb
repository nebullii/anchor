class AddGcpCredentialsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :gcp_service_account_email,            :string  unless column_exists?(:users, :gcp_service_account_email)
    add_column :users, :encrypted_gcp_service_account_key,    :text    unless column_exists?(:users, :encrypted_gcp_service_account_key)
    add_column :users, :encrypted_gcp_service_account_key_iv, :string  unless column_exists?(:users, :encrypted_gcp_service_account_key_iv)
  end
end
