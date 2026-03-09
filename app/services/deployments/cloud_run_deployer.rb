module Deployments
  # Orchestrates the full deployment pipeline for a single Deployment record:
  #
  #   1. Clone repository
  #   2. Detect framework
  #   3. Generate Dockerfile (if absent)
  #   4. Build container image via Cloud Build (gcloud CLI)
  #   5. Deploy to Cloud Run (gcloud CLI)
  #   6. Persist results and transition status
  #
  # Usage:
  #   result = Deployments::CloudRunDeployer.new(deployment).call
  #   result.success? # => true / false
  #   result.url      # => "https://my-service-xyz.run.app"
  #
  class CloudRunDeployer
    Result = Struct.new(:success, :url, :error, keyword_init: true) do
      def success? = success
      def failure? = !success
    end

    # Statuses that map to each pipeline step — used for granular Turbo updates.
    STEP_STATUSES = {
      clone:    "cloning",
      detect:   "detecting",
      build:    "building",
      deploy:   "deploying"
    }.freeze

    def initialize(deployment)
      @deployment = deployment
      @project    = deployment.project
      @user       = @project.user
      @repo_path  = nil
    end

    def call
      log "Starting deployment pipeline"
      run_pipeline
    rescue Deployments::DeploymentError => e
      handle_failure(e.message)
    rescue StandardError => e
      handle_failure("Unexpected error: #{e.class} — #{e.message}")
    ensure
      cleanup_repo
    end

    # ------------------------------------------------------------------ #
    private
    # ------------------------------------------------------------------ #

    # ------------------------------------------------------------------ #
    # Pipeline steps                                                       #
    # ------------------------------------------------------------------ #

    def run_pipeline
      repo_path   = step_clone
      detection   = step_detect(repo_path)
                    step_generate_dockerfile(repo_path, detection)
      image_url   = step_build(repo_path)
      service_url = step_deploy(image_url, detection)

      @deployment.update!(service_url: service_url, image_url: image_url)
      @deployment.transition_to!("success")
      @project.update!(latest_url: service_url)

      log "Pipeline complete. Live at: #{service_url}"
      Result.new(success: true, url: service_url)
    end

    # ------------------------------------------------------------------ #
    # Step 1 — Clone                                                       #
    # ------------------------------------------------------------------ #

    def step_clone
      @deployment.transition_to!(STEP_STATUSES[:clone])
      log "Cloning #{@project.repository.full_name} @ #{branch}..."

      @repo_path = tmp_repo_path
      FileUtils.rm_rf(@repo_path)
      FileUtils.mkdir_p(File.dirname(@repo_path))

      run_shell!(
        "git clone --depth=1 --branch #{shell_escape(branch)} " \
        "#{shell_escape(authenticated_clone_url)} #{shell_escape(@repo_path)}",
        log_output: false   # don't log the URL (contains token)
      )

      sha     = capture_shell("git -C #{shell_escape(@repo_path)} rev-parse HEAD").strip
      message = capture_shell("git -C #{shell_escape(@repo_path)} log -1 --pretty=%s").strip
      @deployment.update!(commit_sha: sha, commit_message: message)

      log "Cloned at commit #{sha[0, 8]}: #{message}"
      @repo_path
    end

    # ------------------------------------------------------------------ #
    # Step 2 — Detect framework                                            #
    # ------------------------------------------------------------------ #

    def step_detect(repo_path)
      @deployment.transition_to!(STEP_STATUSES[:detect])
      log "Detecting framework..."

      detection = FrameworkDetector.new(repo_path, @project).call
      log "Detected: #{detection.framework} / #{detection.runtime} (port #{detection.port})"
      detection
    end

    # ------------------------------------------------------------------ #
    # Step 3 — Generate Dockerfile                                         #
    # ------------------------------------------------------------------ #

    def step_generate_dockerfile(repo_path, detection)
      if File.exist?(File.join(repo_path, "Dockerfile"))
        log "Existing Dockerfile found — skipping generation."
      else
        DockerfileGenerator.new(repo_path, detection).call
        log "Generated Dockerfile for #{detection.framework}."
      end
    end

    # ------------------------------------------------------------------ #
    # Step 4 — Build image via Cloud Build                                 #
    # ------------------------------------------------------------------ #

    def step_build(repo_path)
      @deployment.transition_to!(STEP_STATUSES[:build])
      image_url = full_image_url
      log "Submitting build to Cloud Build..."
      log "Image: #{image_url}"

      # `gcloud builds submit` uploads source to GCS, builds, and pushes to
      # Artifact Registry automatically. Using --tag is the simplest V1 path.
      output = run_shell!(
        "gcloud builds submit " \
        "--project=#{shell_escape(gcp_project_id)} " \
        "--tag=#{shell_escape(image_url)} " \
        "--timeout=30m " \
        "--suppress-logs " \
        "#{shell_escape(repo_path)}"
      )

      # Extract the Cloud Build ID from gcloud output for traceability.
      build_id = output.match(/builds\/([a-f0-9\-]{36})/)&.[](1)
      @deployment.update!(cloud_build_id: build_id) if build_id

      log "Build complete (build_id=#{build_id || 'unknown'})"
      image_url
    end

    # ------------------------------------------------------------------ #
    # Step 5 — Deploy to Cloud Run                                         #
    # ------------------------------------------------------------------ #

    def step_deploy(image_url, detection)
      @deployment.transition_to!(STEP_STATUSES[:deploy])
      log "Deploying #{@project.service_name} to Cloud Run (#{gcp_region})..."

      cmd = build_deploy_command(image_url, detection)
      output = run_shell!(cmd)

      url = extract_service_url(output)
      raise Deployments::DeploymentError, "Could not parse service URL from Cloud Run output" if url.blank?

      log "Deployed successfully at #{url}"
      url
    end

    # ------------------------------------------------------------------ #
    # Helpers — gcloud commands                                            #
    # ------------------------------------------------------------------ #

    def build_deploy_command(image_url, detection)
      port    = detection&.port || 3000
      env_str = Secret.to_cloud_run_env_string(@project)

      parts = [
        "gcloud run deploy #{shell_escape(@project.service_name)}",
        "--project=#{shell_escape(gcp_project_id)}",
        "--region=#{shell_escape(gcp_region)}",
        "--image=#{shell_escape(image_url)}",
        "--platform=managed",
        "--allow-unauthenticated",
        "--port=#{port}",
        "--memory=512Mi",
        "--cpu=1",
        "--min-instances=0",
        "--max-instances=10",
        "--format=json"
      ]
      parts << "--set-env-vars=#{shell_escape(env_str)}" if env_str.present?
      parts.join(" \\\n  ")
    end

    def extract_service_url(output)
      # gcloud run deploy --format=json returns a JSON object with status.url
      json_start = output.index("{")
      if json_start
        json_blob = output[json_start..]
        data = JSON.parse(json_blob)
        url  = data.dig("status", "url")
        return url if url.present?
      end

      # Fallback: scrape the URL from plain-text output.
      output.match(/https:\/\/[\w\-]+\.run\.app/)&.[](0)
    rescue JSON::ParserError
      output.match(/https:\/\/[\w\-]+\.run\.app/)&.[](0)
    end

    # ------------------------------------------------------------------ #
    # Helpers — shell execution                                            #
    # ------------------------------------------------------------------ #

    # Runs a command, streams each line to deployment logs, and raises on failure.
    def run_shell!(command, log_output: true)
      output_lines = []

      IO.popen("#{command} 2>&1") do |io|
        io.each_line do |line|
          line = line.chomp
          output_lines << line
          log(line, source: "cloud_build") if log_output && line.present?
        end
      end

      exit_status = $?
      full_output = output_lines.join("\n")

      unless exit_status.success?
        raise Deployments::DeploymentError, "Command failed (exit #{exit_status.exitstatus}):\n#{full_output.last(20).join("\n")}"
      end

      full_output
    end

    # Runs a command and returns stdout; raises on failure.
    def capture_shell(command)
      result = `#{command} 2>&1`
      raise Deployments::DeploymentError, "Command failed: #{command}\n#{result}" unless $?.success?
      result
    end

    # Shell-escapes a single argument safely.
    def shell_escape(str)
      Shellwords.escape(str.to_s)
    end

    # ------------------------------------------------------------------ #
    # Helpers — GCP identifiers                                            #
    # ------------------------------------------------------------------ #

    def gcp_project_id
      @project.gcp_project_id
    end

    def gcp_region
      @project.gcp_region
    end

    # Full Artifact Registry image URL including deployment ID as tag.
    # Format: REGION-docker.pkg.dev/GCP_PROJECT/cloudlaunch/SERVICE:DEPLOYMENT_ID
    def full_image_url
      "#{gcp_region}-docker.pkg.dev/#{gcp_project_id}/cloudlaunch/#{@project.service_name}:#{@deployment.id}"
    end

    # ------------------------------------------------------------------ #
    # Helpers — repo                                                       #
    # ------------------------------------------------------------------ #

    def branch
      @project.production_branch.presence || @project.repository.default_branch
    end

    def authenticated_clone_url
      @project.repository.authenticated_clone_url
    end

    def tmp_repo_path
      "/tmp/cloudlaunch/#{@project.id}/#{@deployment.id}"
    end

    # ------------------------------------------------------------------ #
    # Helpers — logging & error handling                                   #
    # ------------------------------------------------------------------ #

    def log(message, level: "info", source: "system")
      Rails.logger.info("[Deployment ##{@deployment.id}] #{message}")
      @deployment.append_log(message, level: level, source: source)
    end

    def handle_failure(message)
      Rails.logger.error("[Deployment ##{@deployment.id}] FAILED: #{message}")
      @deployment.update!(error_message: message)
      @deployment.append_log(message, level: "error")
      @deployment.transition_to!("failed")
      Result.new(success: false, error: message)
    end

    def cleanup_repo
      return unless @repo_path && Dir.exist?(@repo_path)
      FileUtils.rm_rf(@repo_path)
      Rails.logger.debug("[Deployment ##{@deployment.id}] Cleaned up #{@repo_path}")
    rescue => e
      Rails.logger.warn("[Deployment ##{@deployment.id}] Cleanup failed: #{e.message}")
    end
  end

end
