class UpdateConcurrentDeploymentGuardForRunningStatus < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  OLD_INDEX = "index_deployments_one_active_per_project".freeze
  NEW_INDEX = "index_deployments_one_active_per_project".freeze

  def up
    remove_index :deployments, name: OLD_INDEX, algorithm: :concurrently if index_exists?(:deployments, :project_id, name: OLD_INDEX)

    add_index :deployments,
              :project_id,
              unique: true,
              where: "status NOT IN ('running', 'success', 'failed', 'cancelled')",
              name: NEW_INDEX,
              algorithm: :concurrently
  end

  def down
    remove_index :deployments, name: NEW_INDEX, algorithm: :concurrently if index_exists?(:deployments, :project_id, name: NEW_INDEX)

    add_index :deployments,
              :project_id,
              unique: true,
              where: "status NOT IN ('success', 'failed', 'cancelled')",
              name: OLD_INDEX,
              algorithm: :concurrently
  end
end
