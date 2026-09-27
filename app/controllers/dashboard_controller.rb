class DashboardController < ApplicationController
  skip_before_action :require_login, only: %i[index pricing]

  # GitHub id of the demo user created by db/seeds.rb.
  DEV_LOGIN_GITHUB_ID = "anchor-demo".freeze

  # The dev login signs anyone in as the seeded demo user without OAuth, so it
  # is gated on BOTH the development environment and an explicit opt-in flag.
  # Production, staging and test can never enable it, whatever ENV says.
  def self.dev_login_enabled?(env: Rails.env, flag: ENV["ANCHOR_DEV_LOGIN"])
    env.to_s == "development" && flag.to_s == "1"
  end

  helper_method :dev_login_enabled?

  def pricing; end

  def index
    if params[:dev_login].present? && !logged_in?
      sign_in_dev_user
      return
    end

    return unless logged_in?

    @projects = current_user.projects.where(draft: false).includes(:repository, :deployments).ordered
    @recent_deployments = current_user.deployments
                                      .includes(:project)
                                      .order(created_at: :desc)
                                      .limit(10)
    @latest_failure = @recent_deployments.first if @recent_deployments.first&.failed?
  end

  private

  def dev_login_enabled?
    self.class.dev_login_enabled?
  end

  def sign_in_dev_user
    return head(:not_found) unless dev_login_enabled?

    user = User.find_by(github_id: DEV_LOGIN_GITHUB_ID)
    unless user
      redirect_to root_path, alert: "Demo user not found. Run `bin/rails db:seed` and try again."
      return
    end

    reset_session
    session[:user_id] = user.id
    redirect_to root_path, notice: "Signed in as the demo user (development only)."
  end
end
