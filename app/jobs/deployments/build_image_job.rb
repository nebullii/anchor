module Deployments
  # DEPRECATED shim — the build step now runs inside PrepareJob via
  # Providers::Base#build!, so no local path is handed between jobs.
  #
  # Kept only so BuildImageJob payloads already sitting in Redis when this
  # version ships don't crash on deserialization. Such a job cannot continue
  # (its repo_path lived on another worker's disk), so it cleans up any local
  # checkout it can see and fails the deployment with a clear message.
  #
  class BuildImageJob < BaseJob
    def perform(deployment_id, repo_path = nil)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "analyzing", "cloning", "detecting")
          raise Deployments::DeploymentError,
                "The deployment pipeline was upgraded while this deploy was in flight. Please redeploy."
        end
      end
    ensure
      cleanup_legacy_checkout(repo_path)
    end

    private

    # Old pipeline checkouts lived under this root; never delete anything else.
    LEGACY_ROOT = "/tmp/cloudlaunch/".freeze

    def cleanup_legacy_checkout(repo_path)
      return if repo_path.blank?
      path = File.expand_path(repo_path.to_s)
      return unless path.start_with?(LEGACY_ROOT) && Dir.exist?(path)
      FileUtils.rm_rf(path)
    end
  end
end
