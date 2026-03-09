class FrameworkDetector
  # Ordered by specificity — more specific checks first.
  DETECTORS = [
    {
      framework: "docker",
      runtime:   "custom",
      port:      8080,
      check:     ->(path) { File.exist?("#{path}/Dockerfile") }
    },
    {
      framework: "rails",
      runtime:   "ruby3.2",
      port:      3000,
      check:     ->(path) {
        File.exist?("#{path}/Gemfile") &&
          File.read("#{path}/Gemfile").include?("rails")
      }
    },
    # Next.js — check before generic node so package.json with "next" wins
    {
      framework: "nextjs",
      runtime:   "node20",
      port:      3000,
      check:     ->(path) {
        pkg = "#{path}/package.json"
        File.exist?(pkg) && JSON.parse(File.read(pkg)).dig("dependencies", "next")
      }
    },
    {
      framework: "node",
      runtime:   "node20",
      port:      3000,
      check:     ->(path) { File.exist?("#{path}/package.json") }
    },
    # FastAPI — check before generic python
    {
      framework: "fastapi",
      runtime:   "python3.11",
      port:      8000,
      check:     ->(path) {
        req     = "#{path}/requirements.txt"
        pyproj  = "#{path}/pyproject.toml"
        (File.exist?(req)    && File.read(req).match?(/^fastapi/i)) ||
        (File.exist?(pyproj) && File.read(pyproj).include?("fastapi"))
      }
    },
    # Flask — check before generic python
    {
      framework: "flask",
      runtime:   "python3.11",
      port:      5000,
      check:     ->(path) {
        req = "#{path}/requirements.txt"
        File.exist?(req) && File.read(req).match?(/^flask/i)
      }
    },
    # Django — manage.py is the strongest signal
    {
      framework: "django",
      runtime:   "python3.11",
      port:      8000,
      check:     ->(path) {
        req = "#{path}/requirements.txt"
        File.exist?("#{path}/manage.py") ||
          (File.exist?(req) && File.read(req).match?(/^django/i))
      }
    },
    {
      framework: "python",
      runtime:   "python3.11",
      port:      8000,
      check:     ->(path) {
        File.exist?("#{path}/requirements.txt") ||
          File.exist?("#{path}/pyproject.toml") ||
          File.exist?("#{path}/setup.py")
      }
    },
    # Static — only match when there are no server-side signals
    {
      framework: "static",
      runtime:   "nginx",
      port:      80,
      check:     ->(path) {
        File.exist?("#{path}/index.html") &&
          !File.exist?("#{path}/package.json") &&
          !File.exist?("#{path}/requirements.txt") &&
          !File.exist?("#{path}/Gemfile")
      }
    }
  ].freeze

  DEFAULT = { framework: "static", runtime: "nginx", port: 80 }.freeze

  Result = Struct.new(:framework, :runtime, :port, :metadata, keyword_init: true)

  def initialize(repo_path, project)
    @repo_path = repo_path
    @project   = project
  end

  def call
    detected = DETECTORS.find { |d| safe_check(d, @repo_path) } || DEFAULT
    metadata = build_metadata(detected[:framework])
    port     = resolve_port(detected[:framework], detected[:port], metadata)

    # Persist detection onto the project's own columns.
    @project.update_columns(
      framework: detected[:framework],
      runtime:   detected[:runtime],
      port:      port
    )

    Result.new(
      framework: detected[:framework],
      runtime:   detected[:runtime],
      port:      port,
      metadata:  metadata
    )
  end

  private

  def safe_check(detector, path)
    detector[:check].call(path)
  rescue => e
    Rails.logger.warn("FrameworkDetector check failed for #{detector[:framework]}: #{e.message}")
    false
  end

  def build_metadata(framework)
    case framework
    when "rails"
      {
        "ruby_version"  => detect_ruby_version,
        "bundler_lock"  => File.exist?("#{@repo_path}/Gemfile.lock")
      }
    when "nextjs", "node"
      package_json = JSON.parse(File.read("#{@repo_path}/package.json"))
      {
        "node_version"   => detect_node_version,
        "start_script"   => package_json.dig("scripts", "start"),
        "build_script"   => package_json.dig("scripts", "build"),
        "main"           => package_json["main"],
        "has_lock_file"  => File.exist?("#{@repo_path}/package-lock.json") ||
                            File.exist?("#{@repo_path}/yarn.lock") ||
                            File.exist?("#{@repo_path}/pnpm-lock.yaml")
      }
    when "fastapi"
      {
        "has_requirements" => File.exist?("#{@repo_path}/requirements.txt"),
        "entry_point"      => detect_fastapi_entry,
        "has_procfile"     => File.exist?("#{@repo_path}/Procfile")
      }
    when "flask"
      {
        "has_requirements" => File.exist?("#{@repo_path}/requirements.txt"),
        "entry_point"      => detect_python_entry,
        "has_procfile"     => File.exist?("#{@repo_path}/Procfile")
      }
    when "django"
      {
        "has_requirements" => File.exist?("#{@repo_path}/requirements.txt"),
        "has_procfile"     => File.exist?("#{@repo_path}/Procfile"),
        "wsgi_module"      => detect_django_wsgi
      }
    when "python"
      {
        "has_requirements" => File.exist?("#{@repo_path}/requirements.txt"),
        "has_pyproject"    => File.exist?("#{@repo_path}/pyproject.toml"),
        "has_procfile"     => File.exist?("#{@repo_path}/Procfile"),
        "entry_point"      => detect_python_entry
      }
    else
      {}
    end
  rescue => e
    Rails.logger.warn("FrameworkDetector#build_metadata failed: #{e.message}")
    {}
  end

  def resolve_port(framework, default_port, metadata)
    case framework
    when "node"
      # Check if start script hard-codes a PORT env var.
      start_script = metadata["start_script"].to_s
      port_match   = start_script.match(/PORT[=\s]+(\d+)/)
      port_match ? port_match[1].to_i : default_port
    else
      default_port
    end
  end

  # ------------------------------------------------------------------ #
  # Runtime version detection                                            #
  # ------------------------------------------------------------------ #

  def detect_ruby_version
    version_file = "#{@repo_path}/.ruby-version"
    gemfile_lock = "#{@repo_path}/Gemfile.lock"

    if File.exist?(version_file)
      File.read(version_file).strip
    elsif File.exist?(gemfile_lock)
      match = File.read(gemfile_lock).match(/RUBY VERSION\s+ruby (\d+\.\d+)/)
      match ? match[1] : "3.2"
    else
      "3.2"
    end
  end

  def detect_node_version
    nvmrc = "#{@repo_path}/.nvmrc"
    node_version_file = "#{@repo_path}/.node-version"

    if File.exist?(nvmrc)
      File.read(nvmrc).strip.delete_prefix("v")
    elsif File.exist?(node_version_file)
      File.read(node_version_file).strip.delete_prefix("v")
    else
      "20"
    end
  end

  def detect_python_entry
    %w[main.py app.py wsgi.py manage.py server.py].find do |entry|
      File.exist?("#{@repo_path}/#{entry}")
    end
  end

  def detect_fastapi_entry
    # FastAPI apps typically expose an `app` object in main.py or app.py
    %w[main.py app.py server.py api.py].find do |entry|
      path = "#{@repo_path}/#{entry}"
      File.exist?(path) && File.read(path).include?("FastAPI")
    end || "main.py"
  end

  def detect_django_wsgi
    # Try to find the wsgi module from manage.py or settings
    manage = "#{@repo_path}/manage.py"
    if File.exist?(manage)
      match = File.read(manage).match(/DJANGO_SETTINGS_MODULE['"]\s*,\s*['"]([^'"]+)/)
      match ? match[1].sub(/\.settings.*/, ".wsgi") : nil
    end
  end
end
