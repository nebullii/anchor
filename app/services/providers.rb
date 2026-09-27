# Provider abstraction — the seam between Anchor's deployment pipeline and the
# infrastructure a project actually runs on.
#
#   provider = Providers.for(project)
#   provider.provision!(log: ->(line) { ... })
#   ref      = provider.build!(deployment, source_dir, log: ...)
#   status   = provider.build_status(deployment)
#   revision = provider.deploy_revision!(deployment, env: {...}, log: ...)
#   url      = provider.promote!(deployment, log: ...)
#
# See Providers::Base for the full contract.
module Providers
  # project.provider value => implementation class name.
  REGISTRY = {
    "gcp_cloud_run" => "Providers::GcpCloudRun",
    "local_docker"  => "Providers::LocalDocker"
  }.freeze

  NAMES   = REGISTRY.keys.freeze
  DEFAULT = "gcp_cloud_run".freeze

  # Returns a provider instance for the project. Extra keyword arguments
  # (e.g. `runner:`) are forwarded so callers and specs can inject a runner.
  def self.for(project, **opts)
    name       = project.try(:provider).presence || DEFAULT
    class_name = REGISTRY.fetch(name) do
      raise Providers::Error, "Unknown provider '#{name}'. Valid providers: #{NAMES.join(', ')}"
    end
    class_name.constantize.new(project, **opts)
  end

  # Translates provider errors into the pipeline's own error classes so the
  # shared Deployments::BaseJob error handling applies (transient → retried,
  # permanent → deployment marked failed with a readable message).
  def self.translate_errors
    yield
  rescue Providers::TransientError => e
    raise Deployments::TransientError, e.message
  rescue Providers::Error => e
    raise Deployments::DeploymentError, e.message
  end
end
