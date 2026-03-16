class CreateDeploymentEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :deployment_events do |t|
      t.references :deployment, null: false, foreign_key: true
      t.string   :event_type, null: false     # e.g. "status_changed", "log_appended", "resource_created"
      t.string   :from_status
      t.string   :to_status
      t.jsonb    :metadata, default: {}
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :deployment_events, [ :deployment_id, :occurred_at ]
    add_index :deployment_events, :event_type
  end
end
