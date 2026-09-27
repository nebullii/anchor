module Deployments
  # Performs the traffic shift for a rollback Deployment created by
  # Deployments::Rollback.
  #
  #   queued ─▶ deploying ── provider.rollback!(project, revision_name)
  #                │
  #                ├─ ok   → previously live deployment → rolled_back
  #                │         this deployment            → running
  #                └─ error → failed (traffic unchanged; BaseJob handles it)
  #
  # No build and no new revision: the target revision already passed its
  # health check when it was first released.
  #
  class RollbackJob < BaseJob
    def perform(deployment_id)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "queued")

          project  = deployment.project
          previous = Rollback.current_deployment(project)
          previous = nil if previous&.id == deployment.id

          deployment.transition_to!("deploying")
          deployment.append_log("Shifting 100% of traffic to revision #{deployment.revision_name}...")

          result = begin
            Providers.for(project).rollback!(
              project, deployment.revision_name,
              log: ->(line) { deployment.append_log(line.to_s, source: "system") if line.present? }
            )
          rescue Providers::TransientError => e
            raise Deployments::TransientError, e.message
          rescue Providers::Error => e
            raise Deployments::DeploymentError, "Rollback failed: #{e.message}. Traffic was not changed."
          end

          service_url = (result if result.is_a?(String) && result.start_with?("http")) ||
                        previous&.service_url.presence || project.latest_url
          deployment.update!(service_url: service_url)
          project.update!(latest_url: service_url) if service_url.present?

          if previous
            previous.append_log("Rolled back: traffic moved to revision #{deployment.revision_name} (deployment ##{deployment.id}).", level: "warn")
            previous.transition_to!("rolled_back")
          end

          deployment.append_log("Rollback complete. Revision #{deployment.revision_name} is serving 100% of traffic.")
          deployment.append_log("Live at: #{service_url}") if service_url.present?
          deployment.transition_to!("running")
          deployment.supersede_previous!
        end
      end
    end
  end
end
