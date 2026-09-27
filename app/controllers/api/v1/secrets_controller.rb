module Api
  module V1
    # Project secrets (env vars). Values are write-only: the API lists
    # names, and accepts values on PUT, but never returns them.
    class SecretsController < BaseController
      before_action :set_project

      # GET /api/v1/projects/:project_id/secrets
      def index
        render json: { secrets: @project.secrets.ordered.map { |s| secret_json(s) } }
      end

      # PUT /api/v1/projects/:project_id/secrets/:key {value}
      # Creates or replaces the secret. 201 when created, 200 when updated.
      def update
        secret  = @project.secrets.find_or_initialize_by(key: params[:key])
        created = secret.new_record?
        secret.value = params.require(:value).to_s

        if secret.save
          render json: { secret: secret_json(secret) }, status: created ? :created : :ok
        else
          render_error(:validation_failed, secret.errors.full_messages.to_sentence,
                       status: :unprocessable_content)
        end
      end

      # DELETE /api/v1/projects/:project_id/secrets/:key
      def destroy
        @project.secrets.find_by!(key: params[:key]).destroy!
        head :no_content
      end

      private

      def set_project
        @project = find_project(params[:project_id])
      end
    end
  end
end
