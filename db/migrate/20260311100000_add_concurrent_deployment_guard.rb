class AddConcurrentDeploymentGuard < ActiveRecord::Migration[8.1]
  def up
    # Prevent more than one in-progress deployment per project at a time.
    # The partial index only covers the non-terminal statuses so terminal
    # rows (success/failed/cancelled) are not affected.
    execute <<~SQL
      CREATE UNIQUE INDEX index_deployments_one_active_per_project
        ON deployments (project_id)
        WHERE status NOT IN ('success', 'failed', 'cancelled')
    SQL
  end

  def down
    remove_index :deployments, name: :index_deployments_one_active_per_project
  end
end
