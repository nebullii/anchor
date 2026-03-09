class RepositoryAnalyzer
  Result = Struct.new(
    :framework, :runtime, :port,
    :detected_env_vars, :detected_database,
    :dependencies, :has_dockerfile,
    :warnings, :confidence,
    keyword_init: true
  ) do
    def to_h
      super.transform_values { |v| v.is_a?(Struct) ? v.to_h : v }
    end
  end

  def initialize(repo_path, project)
    @repo_path = repo_path
    @project   = project
  end

  def call
    detection = FrameworkDetector.new(@repo_path, @project).call
    env_vars  = Analysis::EnvVarDetector.new(@repo_path, detection.framework).call
    database  = Analysis::DatabaseDetector.new(@repo_path, detection.framework).call
    deps      = Analysis::DependencyReader.new(@repo_path, detection.framework).call

    # If database detected, ensure DATABASE_URL is in env vars
    if database && database["var"].present?
      unless env_vars.any? { |v| v["key"] == database["var"] }
        env_vars.unshift({
          "key"      => database["var"],
          "source"   => database["adapter"],
          "required" => true
        })
      end
    end

    Result.new(
      framework:        detection.framework,
      runtime:          detection.runtime,
      port:             detection.port,
      detected_env_vars: env_vars,
      detected_database: database,
      dependencies:     deps,
      has_dockerfile:   File.exist?(File.join(@repo_path, "Dockerfile")),
      warnings:         build_warnings(detection, deps),
      confidence:       confidence_for(detection.framework)
    )
  end

  private

  def build_warnings(detection, deps)
    warnings = []

    unless File.exist?(File.join(@repo_path, "Dockerfile"))
      warnings << "No Dockerfile found — Anchor will generate one for #{detection.framework}"
    end

    if detection.framework == "static"
      warnings << "Detected as a static site — if this is wrong, ensure your language's dependency file is at the repo root"
    end

    if detection.framework == "fastapi" && !deps.any? { |d| d.downcase.include?("uvicorn") }
      warnings << "uvicorn not found in requirements.txt — add it for production FastAPI serving"
    end

    if detection.framework == "flask" && !deps.any? { |d| d.downcase.include?("gunicorn") }
      warnings << "gunicorn not found in requirements.txt — add it for production Flask serving"
    end

    if detection.framework == "django" && !deps.any? { |d| d.downcase.include?("gunicorn") }
      warnings << "gunicorn not found in requirements.txt — add it for production Django serving"
    end

    if detection.framework == "rails"
      unless File.exist?(File.join(@repo_path, "config", "puma.rb"))
        warnings << "No config/puma.rb found — Anchor will use default Puma settings"
      end
    end

    warnings
  end

  def confidence_for(framework)
    case framework
    when "docker"  then "high"   # explicit Dockerfile = user knows what they're doing
    when "static"  then "low"    # fallback — may be wrong
    else                "high"
    end
  end
end
