class AuthController < ApplicationController
  skip_before_action :require_login

  def callback
    user = User.from_omniauth(request.env["omniauth.auth"])
    session[:user_id] = user.id
    redirect_to session.delete(:return_to) || root_path,
                notice: "Welcome, #{user.github_login}!"
  rescue => e
    Rails.logger.error("OAuth callback error: #{e.message}")
    redirect_to root_path, alert: "Sign in failed. Please try again."
  end

  def google_callback
    current_user.connect_google(request.env["omniauth.auth"])
    redirect_to root_path, notice: "Google Cloud connected as #{current_user.google_email}."
  rescue => e
    Rails.logger.error("Google OAuth error: #{e.message}")
    redirect_to root_path, alert: "Google sign in failed. Please try again."
  end

  def failure
    redirect_to root_path, alert: "Sign in was denied."
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path, notice: "Signed out."
  end
end
