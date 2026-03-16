class DashboardController < ApplicationController
  skip_before_action :require_login, only: [:index, :pricing]

  def pricing; end

  def index
    return unless logged_in?

    @projects = current_user.projects.includes(:repository, :deployments).ordered
    @recent_deployments = current_user.deployments
                                      .includes(:project)
                                      .order(created_at: :desc)
                                      .limit(10)
  end
end
