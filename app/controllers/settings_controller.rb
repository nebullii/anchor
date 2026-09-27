class SettingsController < ApplicationController
  include GcpKeyValidation

  before_action :load_api_tokens, only: :show

  def show; end

  # POST /settings/api_tokens
  # Renders the settings page directly (no redirect) so the plaintext token
  # is shown exactly once and never travels through the flash/session cookie.
  def create_api_token
    name = params[:name].to_s.strip.presence || "CLI token"
    @new_api_token = ApiToken.generate!(user: current_user, name: name)
    load_api_tokens
    response.set_header("Cache-Control", "no-store")
    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: "Could not create token: #{e.record.errors.full_messages.to_sentence}"
  end

  # DELETE /settings/api_tokens/:id
  def revoke_api_token
    ApiToken.where(user: current_user).find(params[:id]).revoke!
    redirect_to settings_path, notice: "API token revoked."
  end

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

  private

  def load_api_tokens
    @api_tokens = ApiToken.where(user: current_user).active.ordered
  end
end
