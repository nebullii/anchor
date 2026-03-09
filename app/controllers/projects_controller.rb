class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy deploy]

  def index
    @projects = current_user.projects.includes(:repository, :deployments).ordered
  end

  def show
    @deployments = @project.deployments.order(created_at: :desc).limit(10)
    @secrets     = @project.secrets.ordered
  end

  def new
    @project    = current_user.projects.new
    @repositories = current_user.repositories.ordered
  end

  def create
    @project = current_user.projects.new(project_params)
    if @project.save
      redirect_to @project, notice: "Project created."
    else
      @repositories = current_user.repositories.ordered
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @repositories = current_user.repositories.ordered
  end

  def update
    if @project.update(project_params)
      redirect_to @project, notice: "Project updated."
    else
      @repositories = current_user.repositories.ordered
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project.destroy
    redirect_to projects_path, notice: "Project deleted."
  end

  def deploy
    @deployment = @project.deployments.create!(
      status:       "pending",
      triggered_by: "manual",
      branch:       @project.production_branch
    )
    DeploymentJob.perform_later(@deployment.id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.prepend(
            "project_#{@project.id}_deployment_list",
            partial: "deployments/row",
            locals:  { deployment: @deployment, show_project: false }
          ),
          turbo_stream.replace(
            "notices",
            partial: "shared/notice",
            locals:  { message: "Deployment queued." }
          )
        ]
      end
      format.html do
        redirect_to project_deployment_path(@project, @deployment),
                    notice: "Deployment started."
      end
    end
  end

  private

  def set_project
    @project = current_user.projects.find(params[:id])
  end

  def project_params
    params.require(:project).permit(
      :name, :repository_id, :gcp_project_id, :gcp_region,
      :production_branch, :auto_deploy
    )
  end
end
