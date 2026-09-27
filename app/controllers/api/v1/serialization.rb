module Api
  module V1
    # JSON shapes for the public API. Kept in one place because the CLI and
    # the MCP server both depend on these exact keys — change with care.
    module Serialization
      private

      def user_json(user)
        {
          id:           user.id,
          github_login: user.github_login,
          name:         user.name,
          email:        user.email,
          quota: {
            deployments_today:      user.deployments_today,
            deployments_this_month: user.deployments_this_month,
            daily_limit:            User::DAILY_DEPLOY_LIMIT,
            monthly_limit:          User::MONTHLY_DEPLOY_LIMIT
          }
        }
      end

      def project_json(project, latest: nil)
        {
          id:                project.id,
          name:              project.name,
          slug:              project.slug,
          status:            project.status,
          framework:         project.framework,
          repository:        project.repository&.full_name,
          production_branch: project.production_branch,
          url:               project.latest_url,
          provider:          project.try(:provider),
          region:            project.gcp_region,
          memory:            project.memory,
          health_check_path: project.health_check_path,
          public_access:     project.public_access,
          root_dir:          project.root_dir,
          analysis_status:   project.analysis_status,
          created_at:        project.created_at,
          updated_at:        project.updated_at,
          latest_deployment: latest && deployment_json(latest)
        }
      end

      def deployment_json(deployment)
        {
          id:             deployment.id,
          project_id:     deployment.project_id,
          status:         deployment.status,
          triggered_by:   deployment.triggered_by,
          branch:         deployment.branch,
          commit_sha:     deployment.commit_sha,
          commit_message: deployment.commit_message,
          service_url:    deployment.service_url,
          revision_name:  deployment.try(:revision_name),
          error_message:  deployment.error_message,
          error_category: deployment.error_category,
          ai_explanation: deployment.ai_error_explanation,
          ai_details:     deployment.ai_error_details,
          started_at:     deployment.started_at,
          finished_at:    deployment.finished_at,
          created_at:     deployment.created_at
        }
      end

      def log_json(log)
        {
          id:        log.id,
          message:   log.message,
          level:     log.level,
          source:    log.source,
          logged_at: log.logged_at
        }
      end

      # Secret values never leave the server — names and timestamps only.
      def secret_json(secret)
        { key: secret.key, created_at: secret.created_at, updated_at: secret.updated_at }
      end
    end
  end
end
