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
    if @deployment.in_progress?
      @deployment.transition_to!("cancelled")
      @deployment.append_log("Deployment cancelled by user.", level: "warn")
    end
    redirect_to project_deployment_path(@project, @deployment),
                notice: "Deployment cancelled."
  end

  def create
    deployment = @project.deployments.create!(
      status:       "queued",
      triggered_by: "manual",
      branch:       @project.production_branch
    )
    DeploymentJob.perform_later(deployment.id)
    redirect_to project_deployment_path(@project, deployment),
                notice: "Deployment started."
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def set_deployment
    @deployment = @project.deployments.find(params[:id])
  end
end
