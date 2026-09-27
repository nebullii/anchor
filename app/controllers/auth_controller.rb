class AuthController < ApplicationController
  skip_before_action :require_login, only: [ :github_callback, :failure, :destroy ]

  # ── GitHub sign-in ──────────────────────────────────────────────────────── #

  def github_callback
    user      = User.from_omniauth(request.env["omniauth.auth"])
    return_to = safe_return_to(session[:return_to])

    # Session fixation: issue a brand-new session on every login so an id
    # planted before authentication is never upgraded to a logged-in one.
    start_session_for(user)

    redirect_to return_to || root_path, notice: "Welcome, #{user.github_login}!"
  rescue => e
    log_oauth_error("GitHub", e)
    redirect_to root_path, alert: "Sign in failed. Please try again."
  end

  # ── Google Cloud connect (requires existing session) ─────────────────────── #

  def google_callback
    auth       = request.env["omniauth.auth"]
    expires_at = auth.credentials.expires_at

    current_user.update!(
      google_email:            auth.info.email,
      google_access_token:     auth.credentials.token,
      google_refresh_token:    auth.credentials.refresh_token.presence || current_user.google_refresh_token,
      google_token_expires_at: expires_at ? Time.at(expires_at) : 1.hour.from_now
    )

    # Linking a cloud credential is a privilege change — rotate the session id.
    start_session_for(current_user)

    redirect_to gcp_projects_path, notice: "Google connected. Now select your GCP project."
  rescue => e
    log_oauth_error("Google", e)
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
    # Drop the whole session (not just user_id) so nothing survives logout.
    reset_session
    redirect_to root_path, notice: "Signed out."
  end

  private

  def start_session_for(user)
    reset_session
    session[:user_id]          = user.id
    session[:authenticated_at] = Time.current.to_i
  end

  # Only same-origin, absolute paths — never "//evil.com" or "https://…".
  def safe_return_to(path)
    path = path.to_s
    return nil unless path.start_with?("/")
    return nil if path.start_with?("//", "/\\")
    path
  end

  # OAuth errors can carry codes or tokens in their messages — scrub first.
  def log_oauth_error(provider, error)
    Rails.logger.error("#{provider} OAuth callback error: #{error.class}: #{Security::Redactor.redact(error.message)}")
  end
end
