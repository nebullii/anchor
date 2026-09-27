module Api
  module V1
    # Base class for the JSON API used by the `anchor` CLI and MCP server.
    #
    # Authentication: `Authorization: Bearer anc_...` (see ApiToken).
    # Errors are always rendered as {"error": {"code": "...", "message": "..."}}.
    # Every lookup is scoped through current_user, so another user's
    # resources are indistinguishable from missing ones (404).
    class BaseController < ActionController::API
      include Api::V1::Serialization

      DEFAULT_LIMIT = 20
      MAX_LIMIT     = 100

      before_action :authenticate_token!

      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, "Resource not found.", status: :not_found)
      end

      rescue_from ActionController::ParameterMissing do |e|
        render_error(:bad_request, e.message, status: :bad_request)
      end

      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error(:bad_request, "Request body is not valid JSON.", status: :bad_request)
      end

      # Raised by the hardened state machine (Backend) on illegal moves.
      # Resolved lazily, so this is a no-op until that class exists.
      rescue_from "Deployment::InvalidTransition" do |e|
        render_error(:invalid_transition, e.message, status: :conflict)
      end

      attr_reader :current_user, :current_api_token

      private

      def authenticate_token!
        raw = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
        @current_api_token = ApiToken.authenticate(raw) if raw
        @current_user      = @current_api_token&.user
        return if @current_user

        response.set_header("WWW-Authenticate", 'Bearer realm="anchor"')
        message = raw ? "API token is invalid or has been revoked." :
                        "Missing API token. Send `Authorization: Bearer <token>`."
        render_error(:unauthorized, message, status: :unauthorized)
      end

      def render_error(code, message, status:, **extra)
        render json: { error: { code: code.to_s, message: message }.merge(extra) }, status: status
      end

      # Clamped `?limit=` for list endpoints.
      def limit_param(default: DEFAULT_LIMIT, max: MAX_LIMIT)
        value = params[:limit].presence&.to_i || default
        value.clamp(1, max)
      end

      # Projects are addressable by numeric id or by slug.
      def find_project(identifier)
        scope = current_user.projects.includes(:repository)
        identifier.to_s.match?(/\A\d+\z/) ? scope.find(identifier) : scope.find_by!(slug: identifier.to_s)
      end

      def find_deployment(id)
        current_user.deployments.find(id)
      end
    end
  end
end
