# frozen_string_literal: true

module GcpRequirement
  extend ActiveSupport::Concern

  included do
    before_action :require_gcp_credentials, only: %i[new create]
  end

  private

  def require_gcp_credentials
    return if current_user.google_connected?

    if request.format.turbo_stream?
      flash.now[:alert] = "Google Cloud credentials required. Please connect your GCP account in Settings first."
      render turbo_stream: turbo_stream.replace(
        "notices",
        partial: "shared/notice",
        locals: { message: "Google Cloud credentials required. Please connect your GCP account in Settings first.", alert: true }
      ), status: :unprocessable_entity
    else
      redirect_to settings_path, alert: "Google Cloud credentials required. Please connect your GCP account in Settings first."
    end
  end
end
