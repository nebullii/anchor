class DeployWizardController < ApplicationController
  include GcpKeyValidation
  before_action :set_project, only: %i[analyzing configure launch]

  # Step 1 — Pick a repo
  def index
    @repositories = current_user.repositories.ordered
  end

  # Step 2 — Create draft project + trigger analysis
  def create
    repo = current_user.repositories.find_by(id: params[:repository_id])
    unless repo
      redirect_to wizard_path, alert: "Repository not found. Please sync your repos first."
      return
    end

    # If a non-draft project already exists for this repo, go straight to it
    existing = current_user.projects.where(repository: repo, draft: false).first
    if existing
      redirect_to project_path(existing), notice: "A project already exists for #{repo.full_name}."
      return
    end

    # Reuse an existing draft for the same repo, or create a new one
    @project = current_user.projects.find_or_initialize_by(repository: repo, draft: true)

    if @project.new_record?
      base_name = repo.name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

      # Detect actual default branch from GitHub rather than relying on stale local data
      actual_branch = detect_repo_default_branch(repo) || repo.default_branch.presence || "main"
      repo.update_columns(default_branch: actual_branch) if actual_branch != repo.default_branch

      @project.assign_attributes(
        name:              unique_project_name(base_name),
        production_branch: actual_branch,
        gcp_region:        current_user.default_gcp_region.presence || "us-central1",
        target_platform:   "gcp"
      )
    end

    if @project.save
      @project.update_columns(analysis_status: "analyzing")
      RepositoryAnalysisJob.perform_later(@project.id)
      redirect_to wizard_analyzing_path(@project)
    else
      @repositories = current_user.repositories.ordered
      flash[:alert] = @project.errors.full_messages.to_sentence
      redirect_to wizard_path
    end
  end

  # Step 3 — Show analysis progress (auto-refreshes until complete)
  def analyzing
    # If analysis is done, redirect to configure
    if @project.analysis_complete? || @project.analysis_status == "failed"
      redirect_to wizard_configure_path(@project) and return
    end

    # If analysis hasn't started yet (e.g. job queued but not running), kick it off
    if @project.analysis_status == "pending"
      @project.update_columns(analysis_status: "analyzing")
      RepositoryAnalysisJob.perform_later(@project.id)
    end
  end

  # Step 4 — Configure GCP credentials + environment variables
  def configure
    @result   = @project.analysis_result || {}
    @env_vars = @result["detected_env_vars"] || []

    # AI suggestions not yet set as secrets
    ai_suggestions = @result["ai_env_var_suggestions"] || []
    existing_keys  = @project.secrets.pluck(:key)
    @extra_vars    = ai_suggestions.reject { |v| existing_keys.include?(v["key"]) }
  end

  # Step 5 — Save credentials + secrets, finalize project, kick off deployment
  def launch
    # 1. Save GCP service account key if submitted
    if params[:gcp_service_account_key].present?
      key_json = params[:gcp_service_account_key].strip

      begin
        parsed = JSON.parse(key_json)
      rescue JSON::ParserError
        redirect_to wizard_configure_path(@project), alert: "Invalid JSON — paste the full service account key file." and return
      end

      if (error = validate_service_account_key(parsed))
        redirect_to wizard_configure_path(@project), alert: error and return
      end

      current_user.update!(
        gcp_service_account_key:   key_json,
        default_gcp_project_id:    parsed["project_id"],
        gcp_service_account_email: parsed["client_email"]
      )
    end

    # 2. Must have GCP configured to proceed
    unless current_user.google_connected?
      redirect_to wizard_configure_path(@project), alert: "GCP credentials are required to deploy." and return
    end

    # 3. Save environment variable secrets from form
    (params[:secrets] || {}).each do |key, value|
      next if value.blank?
      secret = @project.secrets.find_or_initialize_by(key: key)
      secret.value = value
      unless secret.save
        redirect_to wizard_configure_path(@project),
                    alert: "Could not save secret #{key}: #{secret.errors.full_messages.to_sentence}" and return
      end
    end

    # 4. Resolve GCP project ID
    gcp_project_id = current_user.gcp_project_from_key.presence ||
                     current_user.default_gcp_project_id.presence ||
                     params[:gcp_project_id].presence

    unless gcp_project_id.present?
      redirect_to wizard_configure_path(@project),
                  alert: "Could not determine GCP project ID. Check your service account key." and return
    end

    gcp_region = params[:gcp_region].presence ||
                 current_user.default_gcp_region.presence ||
                 "us-central1"

    # 5. Finalize project (exit draft mode)
    unless @project.update(draft: false, gcp_project_id: gcp_project_id, gcp_region: gcp_region)
      redirect_to wizard_configure_path(@project),
                  alert: "Project configuration error: #{@project.errors.full_messages.to_sentence}" and return
    end

    # 6. Provision GCP infrastructure
    Gcp::ProvisionProjectJob.perform_later(@project.id)

    # 7. Check deploy quota
    unless current_user.within_deploy_quota?
      redirect_to project_path(@project),
                  alert: "Daily deployment quota reached (#{User::DAILY_DEPLOY_LIMIT}/day). Try again tomorrow." and return
    end

    # 8. Create and queue deployment
    deployment = @project.deployments.create!(
      status:       "queued",
      triggered_by: "manual",
      branch:       @project.production_branch
    )
    current_user.increment_deploy_quota!
    DeploymentJob.perform_later(deployment.id)

    redirect_to project_deployment_path(@project, deployment),
                notice: "Deployment started! Your app is building and deploying now."
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to wizard_path, alert: "Project not found."
  end

  def detect_repo_default_branch(repo)
    url   = repo.authenticated_clone_url
    out   = `git ls-remote --symref #{Shellwords.escape(url)} HEAD 2>&1`
    match = out.match(%r{ref: refs/heads/(\S+)\s+HEAD})
    match&.captures&.first
  rescue
    nil
  end

  def unique_project_name(base)
    candidate = base
    counter   = 1
    while current_user.projects.exists?(name: candidate)
      candidate = "#{base}-#{counter}"
      counter  += 1
    end
    candidate
  end
end
