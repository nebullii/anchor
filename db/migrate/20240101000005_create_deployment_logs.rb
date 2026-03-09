class CreateDeploymentLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :deployment_logs do |t|
      t.references :deployment, null: false, foreign_key: true

      t.text     :message,    null: false
      t.string   :level,      null: false, default: "info"
      # info | warn | error | debug
      t.string   :source,     default: "system"
      # system | cloud_build | cloud_run
      t.datetime :logged_at,  null: false

      t.timestamps
    end

    add_index :deployment_logs, :level
    add_index :deployment_logs, :logged_at
    add_index :deployment_logs, [:deployment_id, :logged_at]
  end
end
