class SettingsController < ApplicationController
  include GcpKeyValidation

  def show; end

  def gcp_credentials
    key_json = params[:gcp_service_account_key].to_s.strip

    if key_json.blank?
      return redirect_to settings_path, alert: "Service account key cannot be blank."
    end

    parsed = JSON.parse(key_json)

    if (error = validate_service_account_key(parsed))
      return redirect_to settings_path, alert: error
    end

    current_user.update!(
      gcp_service_account_key:   key_json,
      default_gcp_project_id:    parsed["project_id"],
      gcp_service_account_email: parsed["client_email"]
    )
    redirect_to settings_path, notice: "GCP credentials saved. You can now deploy projects."

  rescue JSON::ParserError
    redirect_to settings_path, alert: "Invalid JSON. Paste the full service account key file contents."
  end
end
