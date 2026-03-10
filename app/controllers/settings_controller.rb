class SettingsController < ApplicationController
  def show; end

  def gcp_credentials
    key_json = params[:gcp_service_account_key].to_s.strip

    if key_json.blank?
      return redirect_to settings_path, alert: "Service account key cannot be blank."
    end

    parsed = JSON.parse(key_json)

    unless parsed["type"] == "service_account" && parsed["client_email"].present?
      return redirect_to settings_path,
                         alert: "Invalid service account key. Make sure you downloaded a Service Account JSON key."
    end

    current_user.update!(gcp_service_account_key: key_json)
    redirect_to settings_path, notice: "GCP credentials saved. You can now deploy projects."

  rescue JSON::ParserError
    redirect_to settings_path, alert: "Invalid JSON. Paste the full service account key file contents."
  end
end
