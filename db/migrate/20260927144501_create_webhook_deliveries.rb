# Ledger of GitHub webhook deliveries (X-GitHub-Delivery) already processed.
# GitHub redelivers on timeouts and users can hit "Redeliver" in the UI; the
# unique index makes each delivery trigger at most one deployment, even when
# two app instances receive the same delivery concurrently.
class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.string   :provider,    null: false, default: "github"
      t.string   :delivery_id, null: false
      t.string   :event,       null: false
      t.bigint   :project_id
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :webhook_deliveries, %i[provider delivery_id], unique: true
    add_index :webhook_deliveries, :received_at
  end
end
