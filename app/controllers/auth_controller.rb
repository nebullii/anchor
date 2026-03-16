class AuthController < ApplicationController
  skip_before_action :require_login, only: [ :github_callback, :failure, :destroy ]

  # ── GitHub sign-in ──────────────────────────────────────────────────────── #

  def github_callback
    user = User.from_omniauth(request.env["omniauth.auth"])
    session[:user_id] = user.id
    redirect_to session.delete(:return_to) || root_path,
                notice: "Welcome, #{user.github_login}!"
  rescue => e
    Rails.logger.error("GitHub OAuth callback error: #{e.message}")
    redirect_to root_path, alert: "Sign in failed. Please try again."
  end

  # ── Google Cloud connect (requires existing session) ─────────────────────── #

  def google_callback
    auth = request.env["omniauth.auth"]

    current_user.update!(
      google_email:            auth.info.email,
      google_access_token:     auth.credentials.token,
      google_refresh_token:    auth.credentials.refresh_token.presence || current_user.google_refresh_token,
      google_token_expires_at: Time.at(auth.credentials.expires_at)
    )

    redirect_to gcp_projects_path, notice: "Google connected. Now select your GCP project."
  rescue => e
    Rails.logger.error("Google OAuth callback error: #{e.message}")
    redirect_to settings_path, alert: "Failed to connect Google Cloud. Please try again."
  end

  def google_disconnect
    current_user.update!(
      google_email:            nil,
      google_access_token:     nil,
      google_refresh_token:    nil,
      google_token_expires_at: nil
    )
    redirect_to settings_path, notice: "Google Cloud disconnected."
  end

  # ── Shared ───────────────────────────────────────────────────────────────── #

  def failure
    redirect_to root_path, alert: "Sign in was denied."
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path, notice: "Signed out."
  end
end
