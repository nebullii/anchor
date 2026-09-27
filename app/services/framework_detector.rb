class FrameworkDetector
  # Detects the framework, runtime and port of the app in a checked-out repo.
  #
  # Detection is manifest-driven (Gemfile.lock, package.json + lockfiles,
  # pyproject/requirements/Pipfile/uv.lock, go.mod, mix.exs, Dockerfile) —
  # see Analysis::DirectoryDetector — and monorepo-aware (see
  # Analysis::AppLocator). The result explains itself: `confidence` is a
  # 0..1 score and `evidence` lists the file:line facts behind the decision.
  #
  # Result stays backward compatible: framework, runtime, port and metadata
  # keep their meaning; confidence, evidence, root_dir, candidates and errors
  # are additions (and may be nil on Results built by hand).
  DEFAULT = { framework: "static", runtime: "nginx", port: 8080 }.freeze

  Result = Struct.new(:framework, :runtime, :port, :metadata,
                      :confidence, :evidence, :root_dir, :candidates, :errors,
                      keyword_init: true) do
    # Directory of the app relative to the repo root ("." for single-app repos).
    def app_dir
      dir = root_dir.presence || metadata&.dig("root_dir")
      dir.presence || "."
    end

    # Absolute path of the app inside a checkout.
    def app_path(repo_path)
      app_dir == "." ? repo_path : File.join(repo_path, app_dir)
    end
  end

  def initialize(repo_path, project, root_dir: nil)
    @repo_path = repo_path
    @project   = project
    @root_dir  = root_dir
  end

  def call
    located = Analysis::AppLocator.new(@repo_path, root_dir: configured_root_dir).call
    chosen  = located.chosen

    metadata = chosen.metadata.dup
    metadata["root_dir"] = chosen.root_dir unless chosen.root_dir == "."

    # Persist detection onto the project's own columns.
    @project&.update_columns(
      framework: chosen.framework,
      runtime:   chosen.runtime,
      port:      chosen.port
    )

    Result.new(
      framework:  chosen.framework,
      runtime:    chosen.runtime,
      port:       chosen.port,
      metadata:   metadata,
      confidence: chosen.confidence,
      evidence:   chosen.evidence,
      root_dir:   chosen.root_dir,
      candidates: located.candidates.map { |c| candidate_summary(c) },
      errors:     located.candidates.flat_map { |c| Array(c.errors) }.uniq
    )
  rescue => e
    # Detection must never take down analysis or a deploy.
    Rails.logger.warn("FrameworkDetector failed: #{e.class}: #{e.message}")
    Result.new(**DEFAULT, metadata: { "undetected" => true }, confidence: 0.0,
               evidence: [], root_dir: ".", candidates: [],
               errors: [ { "file" => nil, "line" => nil, "message" => "detection failed: #{e.message}" } ])
  end

  private

  # An explicit root_dir argument wins, then the project's root_dir column
  # (when the schema has one).
  def configured_root_dir
    return @root_dir if @root_dir.present?
    return nil unless @project.respond_to?(:root_dir)

    @project.root_dir.presence
  end

  def candidate_summary(c)
    {
      "root_dir"   => c.root_dir,
      "framework"  => c.framework,
      "runtime"    => c.runtime,
      "port"       => c.port,
      "confidence" => c.confidence
    }
  end
end
