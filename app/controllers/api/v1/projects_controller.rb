module Api
  module V1
    # Read access to projects plus the rollback action.
    class ProjectsController < BaseController
      before_action :set_project, only: %i[show analysis rollback]

      # GET /api/v1/projects?limit=
      def index
        projects = current_user.projects.includes(:repository).ordered.limit(limit_param(default: 50))
        latest   = latest_deployments_for(projects)
        render json: { projects: projects.map { |p| project_json(p, latest: latest[p.id]) } }
      end

      # GET /api/v1/projects/:id  (numeric id or slug)
      def show
        render json: { project: project_json(@project, latest: @project.latest_deployment) }
      end

      # GET /api/v1/projects/:id/analysis
      # The stored analysis_result plus its preflight findings, pulled out
      # to the top level so clients don't need to know the storage layout.
      def analysis
        result = @project.analysis_result || {}
        render json: {
          analysis: {
            status:      @project.analysis_status,
            analyzed_at: @project.analyzed_at,
            framework:   @project.framework,
            preflight:   Array(result["preflight"] || result["preflight_findings"]),
            result:      result
          }
        }
      end

      # POST /api/v1/projects/:id/rollback {deployment_id?}
      # Delegates to Deployments::Rollback (SRE). Returns 501 until it exists.
      def rollback
        rollback_class = "Deployments::Rollback".safe_constantize
        unless rollback_class
          return render_error(:not_implemented, "Rollback is not available on this server yet.",
                              status: :not_implemented)
        end

        if @project.has_active_deployment?
          return render_error(:deploy_in_progress, "A deployment is already in progress.", status: :conflict)
        end

        target     = params[:deployment_id].present? ? @project.deployments.find(params[:deployment_id]) : nil
        deployment = rollback_class.new(project: @project, target: target, user: current_user).call
        render json: { deployment: deployment_json(deployment) }, status: :accepted
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        render_error(:rollback_failed, e.message, status: :unprocessable_content)
      rescue StandardError => e
        # Service-specific errors (e.g. "no previous deployment to roll
        # back to") are reported as 422; anything else is a real bug.
        raise unless e.class.name.start_with?("Deployments::Rollback")
        render_error(:rollback_failed, e.message, status: :unprocessable_content)
      end

      private

      def set_project
        @project = find_project(params[:id])
      end

      # One query for the newest deployment of each listed project.
      def latest_deployments_for(projects)
        ids = projects.map(&:id)
        return {} if ids.empty?

        Deployment.where(project_id: ids)
                  .select("DISTINCT ON (project_id) deployments.*")
                  .order(Arel.sql("project_id, created_at DESC"))
                  .index_by(&:project_id)
      end
    end
  end
end
