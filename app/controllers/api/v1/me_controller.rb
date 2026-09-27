module Api
  module V1
    # GET /api/v1/me — who the token belongs to. The CLI uses this to
    # validate a token during `anchor login`.
    class MeController < BaseController
      def show
        render json: {
          user:  user_json(current_user),
          token: { id: current_api_token.id, name: current_api_token.name }
        }
      end
    end
  end
end
