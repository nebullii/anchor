class DeploymentsController < ApplicationController
  before_action :set_project
  before_action :set_deployment, only: %i[show cancel]

  def index
    @deployments = @project.deployments.order(created_at: :desc).limit(20)
  end

  def show
    @logs   = @deployment.deployment_logs.chronological
    @events = @deployment.deployment_events.chronological
  end

  def cancel
    @deployment.cancel!(reason: "Deployment cancelled by #{current_user.display_name}.")
    redirect_to project_deployment_path(@project, @deployment), notice: "Deployment cancelled."
  rescue Deployment::InvalidTransition
    redirect_to project_deployment_path(@project, @deployment),
                alert: "Deployment is already #{@deployment.reload.status} and cannot be cancelled."
  end

  def create
    result = Deployments::Starter.new(project: @project, user: current_user).call

    if result.success?
      redirect_to project_deployment_path(@project, result.deployment), notice: "Deployment started."
    elsif result.error_code == :missing_secrets
      redirect_to project_secrets_path(@project), alert: result.message
    else
      redirect_to @project, alert: result.message
    end
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def set_deployment
    @deployment = @project.deployments.find(params[:id])
  end
end
