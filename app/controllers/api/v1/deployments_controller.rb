module Api
  module V1
    # Deployments: list/create under a project, show/logs/cancel by id.
    class DeploymentsController < BaseController
      LOG_DEFAULT_LIMIT = 500
      LOG_MAX_LIMIT     = 1000

      before_action :set_project,    only: %i[index create]
      before_action :set_deployment, only: %i[show logs cancel]

      # GET /api/v1/projects/:project_id/deployments?limit=
      def index
        deployments = @project.deployments.recent.limit(limit_param)
        render json: { deployments: deployments.map { |d| deployment_json(d) } }
      end

      # POST /api/v1/projects/:project_id/deployments {branch?}
      def create
        result = Deployments::Starter.new(
          project:      @project,
          user:         current_user,
          triggered_by: "cli",
          branch:       params[:branch]
        ).call

        if result.success?
          render json: { deployment: deployment_json(result.deployment) }, status: :accepted
        else
          render_start_failure(result)
        end
      end

      # GET /api/v1/deployments/:id
      def show
        render json: { deployment: deployment_json(@deployment) }
      end

      # GET /api/v1/deployments/:id/logs?after_id=&limit=
      # Poll with the returned next_after_id to stream new lines.
      def logs
        after_id = params[:after_id].to_i
        logs     = @deployment.deployment_logs
                              .where("id > ?", after_id)
                              .order(:id)
                              .limit(limit_param(default: LOG_DEFAULT_LIMIT, max: LOG_MAX_LIMIT))
                              .to_a

        render json: {
          logs:          logs.map { |l| log_json(l) },
          next_after_id: logs.last&.id || after_id
        }
      end

      # POST /api/v1/deployments/:id/cancel
      def cancel
        unless @deployment.in_progress?
          return render_error(:not_cancellable,
                              "Deployment is already #{@deployment.status} and cannot be cancelled.",
                              status: :conflict)
        end

        if @deployment.respond_to?(:cancel!)
          @deployment.cancel!
        else
          @deployment.transition_to!("cancelled")
        end
        @deployment.append_log("Deployment cancelled via API.", level: "warn")

        render json: { deployment: deployment_json(@deployment.reload) }
      end

      private

      def set_project
        @project = find_project(params[:project_id])
      end

      def set_deployment
        @deployment = find_deployment(params[:id])
      end

      def render_start_failure(result)
        case result.error_code
        when :missing_secrets
          render_error(:missing_secrets, result.message, status: :unprocessable_content,
                       missing_secrets: result.missing_secrets)
        when :invalid_branch
          render_error(:invalid_branch, result.message, status: :unprocessable_content)
        when :quota_exceeded
          render_error(:quota_exceeded, result.message, status: :too_many_requests)
        else
          render_error(result.error_code, result.message, status: :conflict)
        end
      end
    end
  end
end
