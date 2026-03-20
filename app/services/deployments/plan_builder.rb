module Deployments
  class PlanBuilder
    TARGET = "Google Cloud Run".freeze

    def initialize(project:, analysis_result:, user:)
      @project = project
      @analysis_result = analysis_result || {}
      @user = user
    end

    def call
      required_keys = required_env_keys
      optional_keys = optional_env_keys
      configured_keys = @project.secrets.pluck(:key).to_set
      missing_required = required_keys - configured_keys.to_a

      framework = @analysis_result["framework"] || @project.framework || "unknown"
      runtime   = @analysis_result["runtime"]   || @project.runtime   || "unknown"
      port      = @analysis_result["port"]      || @project.port      || 8080

      {
        # ── Legacy keys (consumed by existing views) ──────────────────
        "framework"                 => framework,
        "runtime"                   => runtime,
        "port"                      => port,
        "container"                 => @analysis_result["has_dockerfile"] ? "Repository Dockerfile" : "Generated Dockerfile",
        "target"                    => TARGET,
        "required_env_vars"         => required_keys,
        "optional_env_vars"         => optional_keys,
        "missing_required_env_vars" => missing_required,
        "deployment_readiness"      => readiness_score(required_keys.size, missing_required.size),
        "risks"                     => Array(@analysis_result["warnings"]).compact.uniq.first(5),
        "ai_env_var_suggestions"    => Array(@analysis_result["ai_env_var_suggestions"]).first(12),

        # ── Structured plan sections ──────────────────────────────────
        "project_type"         => infer_project_type(framework),
        "detected_stack"       => build_detected_stack(framework),
        "deployment_strategy"  => build_deployment_strategy(framework, runtime, port),
        "env_vars"             => build_env_vars_section(required_keys, optional_keys, configured_keys),
        "dependencies"         => build_external_dependencies,
        "provider_plan"        => build_provider_plan(framework),
        "files_to_generate"    => build_files_to_generate(framework),
      }
    end

    private

    # ── Structured section builders ─────────────────────────────────

    def infer_project_type(framework)
      case framework
      when "nextjs"                        then "fullstack_web"
      when "rails", "django", "flask"      then "web_application"
      when "fastapi"                       then "api_service"
      when "node"                          then "web_application"
      when "go"                            then "api_service"
      when "static"                        then "static_site"
      when "bun"                           then "web_application"
      when "elixir"                        then "web_application"
      when "docker"                        then "containerized"
      else                                      "unknown"
      end
    end

    def build_detected_stack(framework)
      db = @analysis_result["detected_database"]
      deps = Array(@analysis_result["dependencies"])

      stack = {
        "framework"        => framework,
        "package_managers" => detect_package_managers(framework)
      }

      stack["database"] = db["adapter"] if db.present?

      if deps.any? { |d| d.to_s.downcase.include?("redis") || d.to_s.downcase.include?("sidekiq") }
        stack["cache"] = "redis"
      end

      stack
    end

    def detect_package_managers(framework)
      case framework
      when "rails"                                then ["bundler"]
      when "python", "fastapi", "flask", "django" then ["pip"]
      when "node", "nextjs"                       then ["npm"]
      when "bun"                                  then ["bun"]
      when "go"                                   then ["go modules"]
      when "elixir"                               then ["mix"]
      else                                             []
      end
    end

    def build_deployment_strategy(framework, runtime, port)
      has_dockerfile = @analysis_result["has_dockerfile"]

      {
        "containerized" => true,
        "entrypoint"    => infer_entrypoint(framework),
        "build_steps"   => infer_build_steps(framework, has_dockerfile),
        "run_command"   => infer_run_command(framework),
        "port"          => port,
        "runtime"       => runtime,
      }
    end

    def infer_entrypoint(framework)
      case framework
      when "rails"   then "bundle exec puma -C config/puma.rb"
      when "node"    then @analysis_result.dig("metadata", "start_script") || "node index.js"
      when "nextjs"  then "node server.js"
      when "fastapi" then "uvicorn main:app --host 0.0.0.0"
      when "flask"   then "gunicorn app:app --bind 0.0.0.0:5000"
      when "django"  then "gunicorn --bind 0.0.0.0:8000 wsgi:application"
      when "go"      then "./app"
      when "bun"     then "bun run start"
      when "elixir"  then "bin/app start"
      when "static"  then "nginx -g 'daemon off;'"
      when "docker"  then "Dockerfile CMD"
      else                "unknown"
      end
    end

    def infer_build_steps(framework, has_dockerfile)
      if has_dockerfile
        return ["docker build (user-provided Dockerfile)"]
      end

      case framework
      when "rails"   then ["bundle install", "rails assets:precompile", "docker build"]
      when "node"    then ["npm install", "npm run build (if present)", "docker build"]
      when "nextjs"  then ["npm install", "npm run build", "docker build (standalone)"]
      when "fastapi" then ["pip install -r requirements.txt", "docker build"]
      when "flask"   then ["pip install -r requirements.txt", "pip install gunicorn", "docker build"]
      when "django"  then ["pip install -r requirements.txt", "pip install gunicorn", "docker build"]
      when "python"  then ["pip install -r requirements.txt", "docker build"]
      when "go"      then ["go mod download", "go build", "docker build (multi-stage)"]
      when "bun"     then ["bun install", "bun run build (if present)", "docker build"]
      when "elixir"  then ["mix deps.get", "mix compile", "mix release", "docker build"]
      when "static"  then ["docker build (nginx)"]
      else                ["docker build"]
      end
    end

    def infer_run_command(framework)
      infer_entrypoint(framework)
    end

    def build_env_vars_section(required_keys, optional_keys, configured_keys)
      detected = Array(@analysis_result["detected_env_vars"])
      ai_suggestions = Array(@analysis_result["ai_env_var_suggestions"])

      required = required_keys.map do |key|
        source_var = detected.find { |v| v["key"]&.upcase == key } ||
                     ai_suggestions.find { |v| v["key"]&.upcase == key }
        {
          "name"            => key,
          "reason"          => source_var&.dig("hint") || source_var&.dig("reason") || "Detected in source code",
          "source_evidence" => source_var&.dig("source") || "code scan",
          "configured"      => configured_keys.include?(key)
        }
      end

      optional = optional_keys.map do |key|
        source_var = detected.find { |v| v["key"]&.upcase == key } ||
                     ai_suggestions.find { |v| v["key"]&.upcase == key }
        {
          "name"            => key,
          "reason"          => source_var&.dig("hint") || source_var&.dig("reason") || "Found in source code",
          "source_evidence" => source_var&.dig("source") || "code scan",
          "configured"      => configured_keys.include?(key)
        }
      end

      { "required" => required, "optional" => optional }
    end

    def build_external_dependencies
      deps = []
      db = @analysis_result["detected_database"]
      all_deps = Array(@analysis_result["dependencies"])

      if db.present?
        deps << {
          "type"     => "database",
          "service"  => db["adapter"],
          "required" => true,
          "notes"    => "Detected from dependency manifest"
        }
      end

      if all_deps.any? { |d| d.to_s.downcase.match?(/\A(redis|sidekiq|resque|bull|ioredis)\z/) }
        deps << {
          "type"     => "cache",
          "service"  => "redis",
          "required" => false,
          "notes"    => "Redis client or queue library detected in dependencies"
        }
      end

      if all_deps.any? { |d| d.to_s.downcase.match?(/\A(aws-sdk|boto3|@aws-sdk)\z/) }
        deps << {
          "type"     => "cloud_service",
          "service"  => "aws",
          "required" => false,
          "notes"    => "AWS SDK detected — ensure IAM credentials are configured"
        }
      end

      deps
    end

    def build_provider_plan(framework)
      {
        "provider" => "google_cloud",
        "services" => [
          "Cloud Run (compute)",
          "Cloud Build (container build)",
          "Artifact Registry (image storage)"
        ],
        "region"   => @project.gcp_region || "us-central1",
        "notes"    => provider_notes(framework)
      }
    end

    def provider_notes(framework)
      notes = []

      notes << "Free tier: 2M requests/month, 360k vCPU-seconds, 180k GiB-seconds"

      unless @project.gcp_provisioned?
        notes << "GCP APIs and Artifact Registry will be provisioned on first deploy"
      end

      if framework == "static"
        notes << "Static site served via nginx container on Cloud Run — consider Cloud Storage + CDN for high-traffic sites"
      end

      db = @analysis_result["detected_database"]
      if db.present? && db["adapter"] != "sqlite"
        notes << "Database not included — provision Cloud SQL or use an external database provider"
      end

      notes
    end

    def build_files_to_generate(framework)
      files = []

      unless @analysis_result["has_dockerfile"]
        files << {
          "path"   => "Dockerfile",
          "reason" => "No Dockerfile found — will generate for #{framework}",
          "action" => "create"
        }
      end

      files << {
        "path"   => ".dockerignore",
        "reason" => "Exclude unnecessary files from container build",
        "action" => "create_if_missing"
      }

      files
    end

    # ── Env var extraction (unchanged) ──────────────────────────────

    def required_env_keys
      detected = Array(@analysis_result["detected_env_vars"]).select { |v| v["required"] }
      from_ai = Array(@analysis_result["ai_env_var_suggestions"]).select do |v|
        v["required"] && v["confidence"].to_s.downcase == "high"
      end

      (detected + from_ai).map { |v| v["key"].to_s.upcase }.reject(&:blank?).uniq.sort
    end

    def optional_env_keys
      detected = Array(@analysis_result["detected_env_vars"]).reject { |v| v["required"] }
      from_ai = Array(@analysis_result["ai_env_var_suggestions"]).reject do |v|
        v["required"] && v["confidence"].to_s.downcase == "high"
      end

      (detected + from_ai).map { |v| v["key"].to_s.upcase }.reject(&:blank?).uniq.sort
    end

    def readiness_score(required_count, missing_required_count)
      env_score =
        if required_count.zero?
          40
        else
          ((required_count - missing_required_count) * 40.0 / required_count).round
        end

      gcp_score = @user.google_connected? ? 20 : 0
      provisioning_score = @project.gcp_provisioned? ? 20 : 10
      analysis_score = @project.analysis_complete? ? 20 : 0

      (env_score + gcp_score + provisioning_score + analysis_score).clamp(0, 100)
    end
  end
end
