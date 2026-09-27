# The one-active-deployment-per-project index listed TERMINAL statuses, so
# every new terminal status (rolled_back, now superseded) needed a migration.
# List the in-progress statuses instead, and mark older live deployments that
# a newer deploy replaced as "superseded".
class IndexActiveDeploymentsByInProgressStatus < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = "index_deployments_one_active_per_project".freeze
  IN_PROGRESS = %w[queued pending analyzing cloning detecting building deploying health_check].freeze

  def up
    remove_index :deployments, name: INDEX, algorithm: :concurrently if index_exists?(:deployments, :project_id, name: INDEX)
    add_index :deployments, :project_id,
              unique:    true,
              where:     "status IN (#{IN_PROGRESS.map { |s| connection.quote(s) }.join(', ')})",
              name:      INDEX,
              algorithm: :concurrently

    # Keep only the newest live deployment per project as running.
    execute <<~SQL
      UPDATE deployments d SET status = 'superseded', status_changed_at = NOW()
      WHERE d.status IN ('running', 'success')
        AND EXISTS (
          SELECT 1 FROM deployments newer
          WHERE newer.project_id = d.project_id
            AND newer.status IN ('running', 'success')
            AND (COALESCE(newer.finished_at, newer.created_at), newer.id) > (COALESCE(d.finished_at, d.created_at), d.id)
        )
    SQL
  end

  def down
    execute "UPDATE deployments SET status = 'running' WHERE status = 'superseded'"
    remove_index :deployments, name: INDEX, algorithm: :concurrently if index_exists?(:deployments, :project_id, name: INDEX)
    add_index :deployments, :project_id,
              unique:    true,
              where:     "status NOT IN ('running', 'success', 'failed', 'cancelled', 'rolled_back')",
              name:      INDEX,
              algorithm: :concurrently
  end
end
