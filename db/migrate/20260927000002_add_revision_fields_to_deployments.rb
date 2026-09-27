# Stateless pipeline + safe rollouts: the build is referenced by an opaque
# provider-specific build_ref (Cloud Build ID, local image tag), and each
# deployment records the revision it created so traffic can be promoted
# or rolled back later.
class AddRevisionFieldsToDeployments < ActiveRecord::Migration[8.1]
  def change
    add_column :deployments, :build_ref,     :string
    add_column :deployments, :revision_name, :string
    add_column :deployments, :revision_url,  :string
    add_index  :deployments, :revision_name
  end
end
