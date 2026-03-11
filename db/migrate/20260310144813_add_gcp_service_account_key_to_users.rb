class AddGcpServiceAccountKeyToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :encrypted_gcp_service_account_key, :text
    add_column :users, :encrypted_gcp_service_account_key_iv, :string
  end
end
