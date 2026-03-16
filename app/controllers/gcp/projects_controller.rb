module Gcp
  class ProjectsController < ApplicationController
    # GET /gcp/projects
    # Lists the user's accessible GCP projects for selection.
    def index
      @projects = Gcp::ProjectsClient.new(current_user.fresh_google_access_token).list
    rescue Gcp::ApiError => e
      Rails.logger.error("[Gcp::ProjectsController] #{e.message}")
      redirect_to root_path,
                  alert: "Could not list your GCP projects. Make sure Google Cloud is connected."
    end

    # POST /gcp/projects
    # Accepts the user's project selection, creates a service account, stores credentials.
    def create
      project_id = params[:gcp_project_id].to_s.strip

      if project_id.blank?
        redirect_to gcp_projects_path, alert: "Please select a GCP project."
        return
      end

      result = Gcp::ServiceAccountCreator.new(
        project_id,
        current_user.fresh_google_access_token
      ).call

      current_user.store_gcp_service_account(
        project_id,
        result[:email],
        result[:key_json]
      )

      redirect_to root_path,
                  notice: "Google Cloud project '#{project_id}' connected. Service account created."
    rescue Gcp::ApiError => e
      Rails.logger.error("[Gcp::ProjectsController] Service account creation failed: #{e.message}")
      redirect_to gcp_projects_path,
                  alert: "Failed to set up service account: #{e.message}"
    end
  end
end
