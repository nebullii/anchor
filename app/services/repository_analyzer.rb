class RepositoryAnalyzer
  # `confidence` stays the coarse "high"/"medium"/"low" label older UI code
  # reads; `confidence_score` (0..1), `evidence`, `root_dir`, `candidates`,
  # `metadata` and `preflight` come from FrameworkDetector / Analysis::Preflight.
  Result = Struct.new(
    :framework, :runtime, :port,
    :detected_env_vars, :detected_database,
    :dependencies, :has_dockerfile,
    :warnings, :confidence,
    :confidence_score, :evidence, :root_dir, :candidates, :metadata,
    :preflight, :detection_errors,
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
    app_path  = detection.app_path(@repo_path)
    env_vars  = Analysis::EnvVarDetector.new(app_path, detection.framework).call
    database  = Analysis::DatabaseDetector.new(app_path, detection.framework).call
    deps      = Analysis::DependencyReader.new(app_path, detection.framework).call

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
      has_dockerfile:   File.exist?(File.join(app_path, "Dockerfile")),
      warnings:         build_warnings(detection, deps, app_path),
      confidence:       confidence_for(detection),
      confidence_score: detection.confidence,
      evidence:         detection.evidence,
      root_dir:         detection.app_dir,
      candidates:       detection.candidates,
      metadata:         detection.metadata,
      preflight:        run_preflight(detection),
      detection_errors: detection.errors
    )
  end

  private

  # Preflight must never fail the analysis; a crash here degrades to "no findings".
  def run_preflight(detection)
    secret_keys = @project.respond_to?(:secrets) ? @project.secrets.pluck(:key) : nil
    Analysis::Preflight.new(@repo_path, detection, project: @project, secret_keys: secret_keys).call
  rescue => e
    Rails.logger.warn("RepositoryAnalyzer preflight failed: #{e.class}: #{e.message}")
    []
  end

  def build_warnings(detection, deps, app_path)
    warnings = []

    unless File.exist?(File.join(app_path, "Dockerfile"))
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
      unless File.exist?(File.join(app_path, "config", "puma.rb"))
        warnings << "No config/puma.rb found — Anchor will use default Puma settings"
      end
    end

    warnings
  end

  def confidence_for(detection)
    return "high" if detection.framework == "docker" # explicit Dockerfile = user knows what they're doing
    return "low"  if detection.framework == "static" # fallback — may be wrong

    score = detection.confidence || 1.0
    if score >= 0.8 then "high"
    elsif score >= 0.5 then "medium"
    else "low"
    end
  end
end
