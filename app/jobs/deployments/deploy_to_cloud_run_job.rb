module Deployments
  # Step 4 of the deployment pipeline: create a new revision WITHOUT traffic.
  #
  # Despite the historical name this job is provider-agnostic — it talks to
  # whatever `Providers.for(project)` returns (Cloud Run, local Docker, ...).
  #
  # Release flow (safe rollout):
  #
  #   building ─▶ deploying ── provider.deploy_revision! (0% traffic)
  #                  │
  #                  ▼
  #             health_check ── HealthCheckJob probes revision URL with backoff
  #                  │                     (re-enqueued via set(wait:), no sleeps)
  #        ┌─────────┴──────────┐
  #      pass                  fail
  #  provider.promote!     provider.delete_revision! (best effort)
  #  status → running      status → failed (error_category "health_check")
  #                        previous revision keeps serving traffic
  #
  # The deployment is never reported "running" before the revision passed its
  # health check, and a bad revision never receives user traffic.
  #
  class DeployToCloudRunJob < BaseJob
    def perform(deployment_id)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "building")

          deployment.transition_to!("deploying")

          project  = deployment.project
          provider = Providers.for(project)
          env      = Secret.to_env_hash(project)

          deployment.append_log("Creating new revision of #{project.service_name} (no traffic yet)...")

          revision = with_provider_errors do
            provider.deploy_revision!(deployment, env: env, log: provider_log(deployment))
          end

          if revision&.url.blank?
            # Without a revision-specific URL we cannot verify the release before
            # promoting it — refuse rather than shift traffic blindly.
            raise Deployments::DeploymentError,
                  "Provider did not return a URL for revision #{revision&.name.inspect}; cannot health check it."
          end

          deployment.update!(revision_name: revision.name, revision_url: revision.url)
          deployment.append_log("Revision #{revision.name} created at #{revision.url}.")

          deployment.transition_to!("health_check")
          HealthCheckJob.perform_later(deployment.id, 1, Time.current.to_f)
        end
      end
    end

    private

    # Streams provider output into the deployment log.
    def provider_log(deployment)
      ->(line) { deployment.append_log(line.to_s, source: "system") if line.present? }
    end

    # Maps provider errors onto the pipeline's error hierarchy so BaseJob
    # handles them uniformly (fail vs. retry).
    def with_provider_errors
      yield
    rescue Providers::TransientError => e
      raise Deployments::TransientError, e.message
    rescue Providers::Error => e
      raise Deployments::DeploymentError, e.message
    end
  end
end
