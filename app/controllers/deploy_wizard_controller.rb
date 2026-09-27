class DeployWizardController < ApplicationController
  include GcpKeyValidation
  before_action :set_project, only: %i[analyzing configure launch]

  # Where the app runs. Local Docker needs no cloud account, so it is the
  # zero-friction path for trying Anchor. Only offered once the Platform
  # migration adds projects.provider (see #providers_supported?).
  PROVIDER_OPTIONS = [
    { id: "local_docker",  label: "Local Docker",     note: "Free, runs on this machine — for trying Anchor" },
    { id: "gcp_cloud_run", label: "Google Cloud Run", note: "Your GCP project, billed by Google" }
  ].freeze
  DEFAULT_PROVIDER = "gcp_cloud_run".freeze

  helper_method :providers_supported?, :selected_provider

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
    provider = requested_provider
    local    = provider == "local_docker"

    # 1–2. Cloud credentials are only needed for Google Cloud Run.
    unless local
      return unless save_gcp_key_from_params

      unless current_user.google_connected?
        redirect_to wizard_configure_path(@project), alert: "GCP credentials are required to deploy to Google Cloud Run. " \
                                                            "Paste a service account key, or choose Local Docker to try Anchor for free." and return
      end
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

    # 4. Resolve GCP project ID (Local Docker keeps a harmless placeholder so
    #    the project-id validation still passes on older schemas).
    gcp_project_id = if local
                       @project.gcp_project_id.presence || "anchor-local"
    else
                       current_user.gcp_project_from_key.presence ||
                         current_user.default_gcp_project_id.presence ||
                         params[:gcp_project_id].presence
    end

    unless gcp_project_id.present?
      redirect_to wizard_configure_path(@project),
                  alert: "Could not determine GCP project ID. Check your service account key." and return
    end

    gcp_region = params[:gcp_region].presence ||
                 current_user.default_gcp_region.presence ||
                 "us-central1"

    # 5. Check deploy quota before provisioning
    unless current_user.within_deploy_quota?
      redirect_to wizard_configure_path(@project),
                  alert: "Daily deployment quota reached (#{User::DAILY_DEPLOY_LIMIT}/day). Try again tomorrow." and return
    end

    # 6. Finalize project (exit draft mode)
    attrs = { draft: false, gcp_project_id: gcp_project_id, gcp_region: gcp_region }
    attrs[:provider] = provider if providers_supported?
    unless @project.update(attrs)
      redirect_to wizard_configure_path(@project),
                  alert: "Project configuration error: #{@project.errors.full_messages.to_sentence}" and return
    end

    # 7. Provision GCP infrastructure (nothing to provision for Local Docker)
    Gcp::ProvisionProjectJob.perform_later(@project.id) unless local

    # 8. Create and queue deployment
    deployment = @project.deployments.create!(
      status:       "queued",
      triggered_by: "manual",
      branch:       @project.production_branch
    )
    current_user.increment_deploy_quota!
    DeploymentJob.perform_later(deployment.id)

    target = local ? "your local Docker" : "Google Cloud Run"
    redirect_to project_deployment_path(@project, deployment),
                notice: "Deployment started! Building and deploying to #{target} now."
  end

  private

  # True once the Platform migration has added projects.provider.
  def providers_supported?
    Project.column_names.include?("provider")
  end

  # Provider preselected on the configure page: the project's own value if
  # set, otherwise Local Docker for users without GCP credentials.
  def selected_provider
    return DEFAULT_PROVIDER unless providers_supported?

    current = @project&.provider.presence
    return current if current && current != DEFAULT_PROVIDER
    current_user.google_connected? ? DEFAULT_PROVIDER : "local_docker"
  end

  # Provider submitted by the configure form, restricted to known values.
  # Falls back to Cloud Run (the only provider) before the migration lands.
  def requested_provider
    return DEFAULT_PROVIDER unless providers_supported?

    allowed = PROVIDER_OPTIONS.map { |o| o[:id] }
    allowed.include?(params[:provider]) ? params[:provider] : DEFAULT_PROVIDER
  end

  # Persists a pasted GCP service account key. Returns false (after
  # redirecting) when the key is invalid, true otherwise.
  def save_gcp_key_from_params
    return true if params[:gcp_service_account_key].blank?

    key_json = params[:gcp_service_account_key].strip
    begin
      parsed = JSON.parse(key_json)
    rescue JSON::ParserError
      redirect_to wizard_configure_path(@project), alert: "Invalid JSON — paste the full service account key file."
      return false
    end

    if (error = validate_service_account_key(parsed))
      redirect_to wizard_configure_path(@project), alert: error
      return false
    end

    current_user.update!(
      gcp_service_account_key:   key_json,
      default_gcp_project_id:    parsed["project_id"],
      gcp_service_account_email: parsed["client_email"]
    )
    true
  end

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
