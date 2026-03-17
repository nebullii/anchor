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
      redirect_to project_deployment_path(@project, @deployment), notice: "Deployment cancelled."
    else
      redirect_to project_deployment_path(@project, @deployment),
                  alert: "Deployment is already #{@deployment.status} and cannot be cancelled."
    end
  end

  def create
    if @project.has_active_deployment?
      return redirect_to @project, alert: "A deployment is already in progress."
    end

    unless current_user.within_deploy_quota?
      return redirect_to @project,
                         alert: "Daily deployment quota reached (#{User::DAILY_DEPLOY_LIMIT}/day). Try again tomorrow."
    end

    missing = @project.missing_required_secrets
    if missing.any?
      return redirect_to project_secrets_path(@project),
                         alert: "Missing required secrets: #{missing.join(', ')}. Add them before deploying."
    end

    deployment = @project.deployments.create!(
      status:       "queued",
      triggered_by: "manual",
      branch:       @project.production_branch
    )
    current_user.increment_deploy_quota!
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
