class HardenDeploymentStateMachine < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = "index_deployments_one_active_per_project".freeze

  # Terminal statuses are excluded from the "one active deployment per project"
  # partial unique index. "rolled_back" is a new terminal status.
  OLD_TERMINAL = %w[running success failed cancelled].freeze
  NEW_TERMINAL = %w[running success failed cancelled rolled_back].freeze

  def up
    # When the deployment entered its current status — used by the reaper to
    # detect deployments stuck in an in-progress status.
    add_column :deployments, :status_changed_at, :datetime unless column_exists?(:deployments, :status_changed_at)
    execute "UPDATE deployments SET status_changed_at = updated_at WHERE status_changed_at IS NULL"
    add_index :deployments, [ :status, :status_changed_at ], algorithm: :concurrently,
              if_not_exists: true

    swap_active_index(NEW_TERMINAL)
  end

  def down
    swap_active_index(OLD_TERMINAL)
    remove_index :deployments, [ :status, :status_changed_at ], algorithm: :concurrently, if_exists: true
    remove_column :deployments, :status_changed_at, if_exists: true
  end

  private

  def swap_active_index(terminal)
    remove_index :deployments, name: INDEX, algorithm: :concurrently if index_exists?(:deployments, :project_id, name: INDEX)
    add_index :deployments, :project_id,
              unique:    true,
              where:     "status NOT IN (#{terminal.map { |s| connection.quote(s) }.join(', ')})",
              name:      INDEX,
              algorithm: :concurrently
  end
end
