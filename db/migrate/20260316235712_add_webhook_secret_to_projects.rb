class AddWebhookSecretToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :webhook_secret, :string
  end
end
