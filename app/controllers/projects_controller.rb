class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy deploy analyze setup_cicd generate_cicd commit_cicd]

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
      RepositoryAnalysisJob.perform_later(@project.id)
      redirect_to @project, notice: "Project created. Analyzing repository…"
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

  def analyze
    @project.update_columns(analysis_status: "analyzing")
    RepositoryAnalysisJob.perform_later(@project.id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "analysis_panel",
          partial: "projects/analysis_panel",
          locals:  { project: @project }
        )
      end
      format.html { redirect_to @project, notice: "Analysis started." }
    end
  end

  def deploy
    missing = @project.missing_required_secrets
    if missing.any?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "missing_secrets_modal",
            partial: "projects/missing_secrets_modal",
            locals:  { project: @project, missing_keys: missing }
          )
        end
        format.html do
          redirect_to project_secrets_path(@project),
                      alert: "Missing required secrets: #{missing.join(', ')}. Add them before deploying."
        end
      end
      return
    end

    @deployment = @project.deployments.create!(
      status:       "queued",
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

  # GET /projects/:id/setup_cicd
  def setup_cicd
    # Reset to 'none' if coming back after a failure or to restart
    if params[:restart].present?
      @project.update_columns(cicd_setup_status: "none", cicd_setup_error: nil, cicd_files: [])
    end
  end

  # POST /projects/:id/generate_cicd
  # Starts the AI scanning job. Returns Turbo Stream to update the panel.
  def generate_cicd
    if @project.cicd_scanning?
      return redirect_to setup_cicd_project_path(@project), alert: "Already scanning."
    end

    @project.update_columns(cicd_setup_status: "scanning", cicd_setup_error: nil, cicd_files: [])
    Projects::SetupCicdJob.perform_later(@project.id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "cicd_setup_panel",
          partial: "projects/cicd_setup_panel",
          locals:  { project: @project, cicd_result: nil, status_message: "Cloning repository and scanning with AI…" }
        )
      end
      format.html { redirect_to setup_cicd_project_path(@project) }
    end
  end

  # POST /projects/:id/commit_cicd
  # Commits the generated files to the user's GitHub repo.
  def commit_cicd
    unless @project.cicd_ready? && @project.cicd_files.any?
      return redirect_to setup_cicd_project_path(@project),
                         alert: "No files ready to commit. Please generate first."
    end

    files_to_commit = @project.cicd_files.map do |f|
      {
        path:    f["path"],
        content: f["content"],
        message: "chore: add #{f['path']} via Anchor CI/CD setup"
      }
    end

    result = Github::FileCommitter.new(
      user:           current_user,
      repo_full_name: @project.repository.full_name,
      branch:         @project.production_branch,
      files:          files_to_commit
    ).call

    if result.success?
      @project.update_columns(
        cicd_setup_status: "committed",
        cicd_committed_at: Time.current
      )
      redirect_to setup_cicd_project_path(@project),
                  notice: "#{result.committed_files.size} file(s) committed to #{@project.repository.full_name}."
    else
      redirect_to setup_cicd_project_path(@project),
                  alert: "Failed to commit files: #{result.error}"
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
