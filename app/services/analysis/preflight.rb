require "yaml"

module Analysis
  # Static checks that catch deploy failures before they cost a cloud build.
  #
  #   Analysis::Preflight.new(repo_path, detection, secret_keys: project.secrets.pluck(:key)).call
  #   # => [{ id: "bind_localhost", severity: "error", message: "...",
  #   #       file: "server.js", line: 12, fix: "..." }, ...]
  #
  # Severities: "error" blocks the deploy (the build or the container will
  # certainly fail), "warning" is very likely a problem, "info" is advice.
  # Findings are sorted deterministically (severity, id, file, line).
  #
  # Every rule is isolated: a rule that raises is skipped (and logged), it
  # never takes the whole analysis down.
  class Preflight
    SEVERITY_ORDER = { "error" => 0, "warning" => 1, "info" => 2 }.freeze

    # id => [severity, summary]. The catalogue exposed to the UI/API/docs.
    RULES = {
      "malformed_manifest"            => [ "error",   "A dependency manifest or lockfile cannot be parsed" ],
      "no_app_detected"               => [ "error",   "Nothing deployable was found in the repository" ],
      "bind_localhost"                => [ "error",   "Server binds to 127.0.0.1/localhost, unreachable from outside the container" ],
      "port_mismatch"                 => [ "error",   "Server listens on a hard-coded port different from the container port" ],
      "port_not_from_env"             => [ "warning", "Server never reads $PORT" ],
      "missing_start_script"          => [ "error",   "Node app has no start script and no entry file" ],
      "nextjs_missing_build_script"   => [ "error",   "Next.js app has no build script" ],
      "nextjs_not_standalone"         => [ "info",    "Next.js output is not standalone (larger image)" ],
      "rails_no_production_database"  => [ "error",   "config/database.yml has no production section" ],
      "rails_sqlite_production"       => [ "warning", "Production uses SQLite on an ephemeral container disk" ],
      "rails_secret_key_base_missing" => [ "warning", "Neither SECRET_KEY_BASE nor RAILS_MASTER_KEY is set" ],
      "rails_master_key_committed"    => [ "error",   "Rails master/credentials key is committed" ],
      "django_allowed_hosts"          => [ "error",   "Django ALLOWED_HOSTS rejects the deployed hostname" ],
      "django_debug_enabled"          => [ "warning", "Django DEBUG is hard-coded to True" ],
      "env_var_not_set"               => [ "warning", "Required environment variable is not set as a project secret" ],
      "dockerfile_expose_mismatch"    => [ "warning", "Dockerfile EXPOSE does not match the configured port" ],
      "dockerfile_no_expose"          => [ "info",    "Dockerfile has no EXPOSE; the default port is assumed" ],
      "dockerfile_runs_as_root"       => [ "info",    "Dockerfile runs the app as root" ],
      "committed_env_file"            => [ "warning", "A .env file is committed" ],
      "committed_secrets"             => [ "error",   "A committed .env file contains secret values" ],
      "committed_dependencies"        => [ "warning", "node_modules / vendored dependencies are committed" ],
      "large_file"                    => [ "warning", "Very large file in the repository" ],
      "large_repository"              => [ "warning", "Repository build context is very large" ],
      "lockfile_missing"              => [ "warning", "No lockfile — builds are not reproducible" ],
      "multiple_lockfiles"            => [ "warning", "More than one JS lockfile" ],
      "workspace_lockfile"            => [ "warning", "Monorepo app relies on a workspace-root lockfile outside its build context" ],
      "go_sum_missing"                => [ "error",   "go.mod has requirements but go.sum is missing" ],
      "go_no_main_package"            => [ "error",   "Go module has no main package" ],
      "runtime_version_unsupported"   => [ "error",   "Runtime version is too old to build" ],
      "runtime_version_eol"           => [ "warning", "Runtime version is end-of-life" ],
      "runtime_version_unrecognized"  => [ "info",    "Runtime version file could not be understood" ],
      "monorepo_ambiguous"            => [ "warning", "Several apps found; the chosen one may be wrong" ],
      "monorepo_candidates"           => [ "info",    "Other apps found in the repository" ],
      "python_server_missing"         => [ "info",    "Production server not declared in dependencies" ]
    }.freeze

    LARGE_FILE_BYTES   = 50 * 1024 * 1024
    LARGE_REPO_BYTES   = 1024 * 1024 * 1024
    MAX_WALK_FILES     = 50_000
    MAX_PER_RULE       = 10
    SOURCE_EXTS = {
      js:     %w[.js .mjs .cjs .ts .mts .cts .jsx .tsx],
      python: %w[.py],
      go:     %w[.go],
      ruby:   %w[.rb],
      elixir: %w[.ex .exs]
    }.freeze
    NON_PROD_PATH = %r{(\A|/)(spec|specs|test|tests|__tests__|e2e|cypress|fixtures|examples?|docs?|scripts)/|\.(test|spec)\.[jt]sx?\z|_test\.go\z|config/environments/(development|test)\.rb\z}

    ENV_SKIP = %w[PORT HOST HOSTNAME NODE_ENV RAILS_ENV RACK_ENV PYTHONUNBUFFERED HOME PATH PWD
                  CI DEBUG TZ LANG MIX_ENV PHX_SERVER PHX_HOST RAILS_MAX_THREADS WEB_CONCURRENCY
                  RAILS_LOG_LEVEL RAILS_LOG_TO_STDOUT RAILS_SERVE_STATIC_FILES PIDFILE
                  JOB_CONCURRENCY SOLID_QUEUE_IN_PUMA NEXT_RUNTIME VERCEL].freeze

    def initialize(repo_path, detection, project: nil, secret_keys: nil)
      @repo_path   = repo_path
      @detection   = detection
      @project     = project
      @secret_keys = secret_keys || (project.respond_to?(:secrets) ? project.secrets.pluck(:key) : nil)
      @findings    = []
    end

    def call
      rules = private_methods(false).grep(/\Acheck_/).sort
      rules.each do |rule|
        send(rule)
      rescue => e
        Rails.logger.warn("Preflight #{rule} failed: #{e.class}: #{e.message}")
      end
      finalize
    end

    private

    # ── Plumbing ─────────────────────────────────────────────────────── #

    def add(id, message, file: nil, line: nil, fix:, severity: nil)
      @findings << {
        id:       id,
        severity: severity || RULES.fetch(id).first,
        message:  message,
        file:     file,
        line:     line,
        fix:      fix
      }
    end

    def finalize
      @findings
        .uniq { |f| [ f[:id], f[:file], f[:line], f[:message] ] }
        .group_by { |f| f[:id] }
        .flat_map { |_, list| list.first(MAX_PER_RULE) }
        .sort_by { |f| [ SEVERITY_ORDER.fetch(f[:severity], 9), f[:id], f[:file].to_s, f[:line].to_i, f[:message] ] }
    end

    def metadata
      @detection&.metadata || {}
    end

    def app_dir
      @detection.respond_to?(:app_dir) ? @detection.app_dir : (metadata["root_dir"].presence || ".")
    end

    def app_files
      @app_files ||= FileSet.new(app_dir == "." ? @repo_path : File.join(@repo_path, app_dir))
    end

    def repo_files
      @repo_files ||= FileSet.new(@repo_path)
    end

    # Repo-relative path for a file relative to the app directory.
    def rel(file)
      app_dir == "." ? file : File.join(app_dir, file)
    end

    # What the app really is, even if it ships its own Dockerfile.
    def framework
      fw = @detection&.framework
      fw == "docker" ? metadata["underlying_framework"] : fw
    end

    def docker?
      @detection&.framework == "docker"
    end

    def expected_port
      @detection&.port
    end

    def node_family?
      %w[node nextjs bun].include?(framework) || (framework == "static" && metadata["build_tool"])
    end

    def source_hits(lang, regex, limit: 50)
      app_files.grep(regex, extensions: SOURCE_EXTS.fetch(lang), limit: limit)
               .reject { |file, _, _| file.match?(NON_PROD_PATH) }
    end

    def references?(lang, regex)
      source_hits(lang, regex, limit: 1).any?
    end

    # Walks the whole checkout once (minus .git) collecting [rel, size].
    def inventory
      @inventory ||= begin
        list = []
        stack = [ "" ]
        until stack.empty? || list.size >= MAX_WALK_FILES
          dir = stack.pop
          abs = dir.empty? ? @repo_path : File.join(@repo_path, dir)
          (Dir.children(abs).sort rescue []).each do |name|
            next if name == ".git"

            rel_path = dir.empty? ? name : File.join(dir, name)
            full = File.join(abs, name)
            next if File.symlink?(full)

            if File.directory?(full)
              stack << rel_path
            else
              list << [ rel_path, (File.size(full) rescue 0) ]
            end
          end
        end
        list.sort
      end
    end

    # ── Detection problems ───────────────────────────────────────────── #

    def check_malformed_manifests
      Array(@detection&.errors).each do |err|
        err = err.stringify_keys
        next unless err["file"]

        add("malformed_manifest", "#{err['file']} could not be parsed: #{err['message']}",
            file: err["file"], line: err["line"],
            fix: "Fix the syntax error (regenerate the lockfile if it has merge conflict markers) and push again.")
      end
    end

    def check_no_app_detected
      return unless metadata["undetected"]

      add("no_app_detected", "No application was detected: no Dockerfile, Gemfile, package.json, Python manifest, go.mod, mix.exs or index.html.",
          fix: "Add a Dockerfile, or point the project's root directory at the folder that contains your app.")
    end

    def check_monorepo
      candidates = Array(@detection&.candidates)
      return if candidates.size < 2

      others = candidates.map { |c| c.stringify_keys }.reject { |c| c["root_dir"] == app_dir }
      return if others.empty?

      list = others.map { |c| "#{c['root_dir']} (#{c['framework']})" }.join(", ")
      if app_dir != "." && !(@project.respond_to?(:root_dir) && @project.root_dir.present?)
        add("monorepo_ambiguous", "Deploying #{app_dir} (#{@detection.framework}); other apps found: #{list}.",
            fix: "Set the project's root directory to the app you want to deploy.")
      else
        add("monorepo_candidates", "Deploying #{app_dir}; other apps in this repository: #{list}.",
            fix: "Create a separate project with a root directory for each app you want deployed.")
      end
    end

    # ── Networking: $PORT and 0.0.0.0 ────────────────────────────────── #

    def check_js_binding
      return unless %w[node bun].include?(framework)

      local = /\.listen\(\s*[^)]*?,\s*["'`](127\.0\.0\.1|localhost)["'`]|listen\(\s*\{[^}]*host\s*:\s*["'`](127\.0\.0\.1|localhost)["'`]|hostname\s*:\s*["'`](127\.0\.0\.1|localhost)["'`]/
      source_hits(:js, local).each do |file, line, text|
        add("bind_localhost", "Server binds to #{text[/127\.0\.0\.1|localhost/]}, so it is unreachable from outside the container.",
            file: rel(file), line: line, fix: %(Listen on "0.0.0.0" (or omit the host argument).))
      end

      listens = source_hits(:js, /\.listen\(|Bun\.serve\(|serve\(\s*\{/)
      return if listens.empty?
      return if references?(:js, /process\.env\.PORT|process\.env\[["']PORT["']\]|Bun\.env\.PORT|import\.meta\.env\.PORT|env\.PORT\b/)

      literal = source_hits(:js, /\.listen\(\s*(\d{2,5})\b|port\s*:\s*(\d{2,5})\b|(?:const|let|var)\s+(?:PORT|port)\s*=\s*(\d{2,5})\b/).first
      report_port(literal, literal&.last&.[](/\d{2,5}/), listens.first, "process.env.PORT")
    end

    def check_python_binding
      # Generated Dockerfiles run FastAPI/Flask/Django under uvicorn/gunicorn
      # bound to 0.0.0.0:$PORT, so app.run() only matters for plain Python
      # apps and custom Dockerfiles.
      return unless framework == "python" || (docker? && %w[fastapi flask django python].include?(framework))

      local = /\.run\([^)]*host\s*=\s*["'](127\.0\.0\.1|localhost)["']|\(\s*\(\s*["'](127\.0\.0\.1|localhost)["']\s*,\s*\d+/
      source_hits(:python, local).each do |file, line, text|
        add("bind_localhost", "Server binds to #{text[/127\.0\.0\.1|localhost/]}, so it is unreachable from outside the container.",
            file: rel(file), line: line, fix: %(Pass host="0.0.0.0".))
      end

      runs = source_hits(:python, /\.run\(|uvicorn\.run\(|serve_forever|HTTPServer\(/)
      return if runs.empty?
      return if references?(:python, /environ(\.get)?\(?\[?\s*["']PORT["']|getenv\(\s*["']PORT["']/)

      literal = source_hits(:python, /port\s*=\s*(\d{2,5})\b|\(\s*["'][^"']*["']\s*,\s*(\d{2,5})\s*\)/).first
      report_port(literal, literal&.last&.[](/\d{2,5}/), runs.first, %(int(os.environ.get("PORT", 8000))))
    end

    def check_go_binding
      return unless framework == "go"

      addr_calls = source_hits(:go, /(ListenAndServe(TLS)?|\.Run|\.Start|\.Listen|net\.Listen)\(\s*("tcp",\s*)?"[^"]*"/)
      addr_calls.each do |file, line, text|
        addr = text[/"((?:127\.0\.0\.1|localhost|\[?::1\]?)?:?\d*)"\s*\)?\s*$/, 1] || text.scan(/"([^"]*)"/).flatten.last.to_s
        next unless addr.match?(/\A(127\.0\.0\.1|localhost|\[::1\])/)

        add("bind_localhost", "Server binds to #{addr}, so it is unreachable from outside the container.",
            file: rel(file), line: line, fix: %(Listen on ":" + os.Getenv("PORT") (all interfaces).))
      end

      return if addr_calls.empty?
      return if references?(:go, /Getenv\(\s*"PORT"\s*\)|LookupEnv\(\s*"PORT"\s*\)/)

      literal = addr_calls.find { |_, _, text| text.match?(/"[^"]*:\d{2,5}"/) }
      report_port(literal, literal&.last&.[](/:(\d{2,5})"/, 1), addr_calls.first, %(":" + os.Getenv("PORT")))
    end

    def check_ruby_binding
      return unless framework == "rails"

      puma = app_files.read("config/puma.rb").to_s
      puma.each_line.with_index(1) do |text, line|
        next if text.strip.start_with?("#")

        if text.match?(/\bbind\s+["']tcp:\/\/(127\.0\.0\.1|localhost)/)
          add("bind_localhost", "Puma binds to localhost, so it is unreachable from outside the container.",
              file: rel("config/puma.rb"), line: line, fix: %(Use `port ENV.fetch("PORT", 3000)` (binds 0.0.0.0).))
        elsif (m = text.match(/\A\s*port\s+(\d{2,5})\b/))
          report_port([ rel("config/puma.rb"), line, text ], m[1], nil, %(ENV.fetch("PORT", 3000)), relative: true)
        end
      end
    end

    def check_elixir_binding
      return unless framework == "elixir"

      %w[config/runtime.exs config/prod.exs].each do |file|
        line = app_files.line_of(file, /ip:\s*\{\s*127\s*,\s*0\s*,\s*0\s*,\s*1\s*\}/)
        next unless line

        add("bind_localhost", "Endpoint binds to 127.0.0.1 in production config.",
            file: rel(file), line: line, fix: "Use ip: {0, 0, 0, 0, 0, 0, 0, 0} in the production endpoint config.")
      end
    end

    # A hard-coded port that differs from the container port is fatal; a
    # matching one works but breaks as soon as the platform picks the port.
    def report_port(literal_hit, literal_port, any_hit, env_expr, relative: false)
      hit  = literal_hit || any_hit
      file = hit && (relative ? hit[0] : rel(hit[0]))
      line = hit && hit[1]

      if literal_port && expected_port && literal_port.to_i != expected_port.to_i
        add("port_mismatch",
            "App listens on port #{literal_port} but the container expects #{expected_port}; the health check will fail.",
            file: file, line: line, fix: "Read the port from the environment: #{env_expr}.")
      else
        add("port_not_from_env", "App never reads $PORT#{literal_port ? " (hard-coded #{literal_port})" : ''}.",
            file: file, line: line, fix: "Read the port from the environment: #{env_expr}.")
      end
    end

    # ── Node / Next.js ───────────────────────────────────────────────── #

    def check_node_start
      return unless %w[node bun].include?(framework) && !docker?
      return if metadata["start_script"]
      return if metadata["node_framework"] == "nuxt" && metadata["build_script"]

      entry = metadata["main"] || (framework == "bun" ? "index.ts" : "index.js")
      return if app_files.exist?(entry)

      add("missing_start_script", %(package.json has no "start" script and #{entry} does not exist, so the container has nothing to run.),
          file: rel("package.json"), line: 1,
          fix: %(Add "start": "node server.js" (your entry file) to package.json scripts.))
    end

    def check_nextjs
      return unless framework == "nextjs"

      unless metadata["build_script"]
        add("nextjs_missing_build_script", %(package.json has no "build" script; the image build runs it to produce .next.),
            file: rel("package.json"), line: 1, fix: %(Add "build": "next build" to package.json scripts.))
      end

      return if docker? || metadata["next_standalone"] || metadata["next_export"]

      add("nextjs_not_standalone", "next.config does not set output: \"standalone\"; the image will ship all of node_modules.",
          file: metadata["next_config"] ? rel(metadata["next_config"]) : nil, line: nil,
          fix: %(Add `output: "standalone"` to next.config for a ~5x smaller image.))
    end

    # ── Rails ────────────────────────────────────────────────────────── #

    def check_rails_database
      return unless framework == "rails"

      content = app_files.read("config/database.yml")
      return unless content

      config = load_erb_yaml(content)
      return unless config.is_a?(Hash)

      production = config["production"]
      unless production.is_a?(Hash)
        add("rails_no_production_database", "config/database.yml has no production section; Rails will not boot in production unless DATABASE_URL is set.",
            file: rel("config/database.yml"), line: nil,
            fix: "Add a production entry (e.g. `url: <%= ENV[\"DATABASE_URL\"] %>`) and set DATABASE_URL as a secret.")
        return
      end

      primary = production["adapter"] ? production : (production["primary"] || production.values.find { |v| v.is_a?(Hash) })
      adapter = primary.is_a?(Hash) ? primary["adapter"].to_s : ""
      return unless adapter.include?("sqlite")

      add("rails_sqlite_production", "Production uses SQLite; container disks are ephemeral, so data is lost on every deploy or restart.",
          file: rel("config/database.yml"), line: app_files.line_of("config/database.yml", /\Aproduction:/),
          fix: "Use a managed PostgreSQL/MySQL database via DATABASE_URL, or mount persistent storage.")
    end

    def check_rails_secrets
      return unless framework == "rails"

      %w[config/master.key config/credentials/production.key].each do |key_file|
        next unless app_files.exist?(key_file)

        add("rails_master_key_committed", "#{key_file} is committed; anyone with repo access can decrypt your credentials.",
            file: rel(key_file), line: nil,
            fix: "Remove it from git (git rm --cached), rotate the credentials, and set RAILS_MASTER_KEY as a project secret.")
      end

      return if @secret_keys.nil?
      return if (@secret_keys & %w[SECRET_KEY_BASE RAILS_MASTER_KEY]).any?

      has_credentials = app_files.exist?("config/credentials.yml.enc") || app_files.exist?("config/credentials/production.yml.enc")
      add("rails_secret_key_base_missing",
          "Rails refuses to boot in production without a secret key base; neither SECRET_KEY_BASE nor RAILS_MASTER_KEY is set.",
          file: has_credentials ? rel("config/credentials.yml.enc") : nil, line: nil,
          fix: has_credentials ? "Set RAILS_MASTER_KEY (contents of config/master.key) as a project secret." : "Set SECRET_KEY_BASE (bin/rails secret) as a project secret.")
    end

    def load_erb_yaml(content)
      YAML.safe_load(content.gsub(/<%=?.*?%>/m, "erb"), aliases: true)
    rescue Psych::Exception
      nil
    end

    # ── Django ───────────────────────────────────────────────────────── #

    def django_settings_files
      settings = metadata["settings_module"]
      files = []
      if settings
        base = settings.tr(".", "/")
        files += [ "#{base}.py", "#{base}/__init__.py", "#{base}/base.py", "#{base}/production.py", "#{base}/prod.py" ]
      end
      files += app_files.files(extensions: [ ".py" ], limit: 2_000).select { |f| f.match?(%r{(\A|/)settings(\.py\z|/)}) }
      files.uniq.select { |f| app_files.exist?(f) }.reject { |f| f.match?(%r{/(dev|development|local|test)[^/]*\.py\z}) }
    end

    def check_django
      return unless framework == "django"

      files = django_settings_files
      dynamic_hosts = files.any? { |f| app_files.read(f).to_s.match?(/ALLOWED_HOSTS.*(environ|getenv|env\(|config\(|split\()/) }

      files.each do |f|
        app_files.read(f).to_s.each_line.with_index(1) do |text, line|
          if text.match?(/\A\s*DEBUG\s*=\s*True\b/)
            add("django_debug_enabled", "DEBUG = True leaks stack traces and settings to visitors.",
                file: rel(f), line: line, fix: %(Use DEBUG = os.environ.get("DEBUG") == "1".))
          end

          next if dynamic_hosts
          next unless (m = text.match(/\A\s*ALLOWED_HOSTS\s*=\s*[\[(](.*)[\])]/))

          hosts = m[1].scan(/["']([^"']*)["']/).flatten
          next if hosts.any? { |h| !%w[localhost 127.0.0.1 ::1 [::1]].include?(h) }

          add("django_allowed_hosts", "ALLOWED_HOSTS = [#{hosts.map { |h| %("#{h}") }.join(', ')}] rejects the deployed hostname with HTTP 400.",
              file: rel(f), line: line,
              fix: %(Read it from the environment: ALLOWED_HOSTS = os.environ.get("ALLOWED_HOSTS", "*").split(",")))
        end
      end
    end

    # ── Environment variables ────────────────────────────────────────── #

    REQUIRED_ENV_PATTERNS = {
      ruby:   [ /ENV\.fetch\(\s*["']([A-Z][A-Z0-9_]{2,})["']\s*\)(?!\s*\{)/, /ENV\[["']([A-Z][A-Z0-9_]{2,})["']\]\s*(?:\|\|)?\s*(?:or\s+)?raise/ ],
      python: [ /os\.environ\[\s*["']([A-Z][A-Z0-9_]{2,})["']\s*\]/ ],
      elixir: [ /System\.fetch_env!\(\s*"([A-Z][A-Z0-9_]{2,})"\s*\)/, /System\.get_env\(\s*"([A-Z][A-Z0-9_]{2,})"\s*\)\s*\|\|\s*\n?\s*raise/ ],
      js:     [ /process\.env\.([A-Z][A-Z0-9_]{2,})!/ ]
    }.freeze

    def check_required_env_vars
      return if @secret_keys.nil?

      seen = {}
      REQUIRED_ENV_PATTERNS.each do |lang, patterns|
        patterns.each do |pattern|
          source_hits(lang, pattern, limit: 200).each do |file, line, text|
            text.scan(pattern).flatten.each do |key|
              next if ENV_SKIP.include?(key) || seen.key?(key)

              seen[key] = [ file, line ]
            end
          end
        end
      end

      # Rails' generated database.yml reads DATABASE_URL implicitly.
      database_var = framework == "rails" && metadata["database_adapter"] && metadata["database_adapter"] != "sqlite" ? "DATABASE_URL" : nil
      seen[database_var] ||= [ nil, nil ] if database_var && !seen.key?(database_var)

      seen.sort.each do |key, (file, line)|
        next if @secret_keys.include?(key)

        add("env_var_not_set", "#{key} is required at runtime#{file ? '' : ' by the detected database'} but is not set as a project secret.",
            file: file && rel(file), line: line, fix: "Add #{key} as a project secret before deploying.")
      end
    end

    # ── Dockerfile ───────────────────────────────────────────────────── #

    def check_dockerfile
      return unless app_files.exist?("Dockerfile")

      dockerfile = Parsers::Dockerfile.parse(app_files.read("Dockerfile").to_s)
      exposed    = dockerfile.exposed_ports

      if exposed.empty?
        add("dockerfile_no_expose", "Dockerfile has no EXPOSE; Anchor assumes port #{expected_port}.",
            file: rel("Dockerfile"), line: nil, fix: "Add `EXPOSE <port>` matching the port your server listens on.")
      elsif expected_port && exposed.none? { |p, _| p == expected_port.to_i }
        add("dockerfile_expose_mismatch", "Dockerfile exposes #{exposed.map(&:first).join(', ')} but the project port is #{expected_port}.",
            file: rel("Dockerfile"), line: exposed.first[1],
            fix: "Make EXPOSE, the server's listen port and the project port agree (prefer reading $PORT).")
      end

      user = dockerfile.final_user
      return unless user.nil? || user.split(":").first.match?(/\A(root|0)\z/)

      add("dockerfile_runs_as_root", "The container runs as root.",
          file: rel("Dockerfile"), line: dockerfile.final_stage.first&.line,
          fix: "Add a non-root user and a `USER` instruction to the final stage.")
    end

    # ── Repository hygiene ───────────────────────────────────────────── #

    SECRET_KEY_RE = /(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|API_KEY|ACCESS_KEY|CREDENTIAL|DATABASE_URL|DSN)/
    ENV_FILE_RE   = /\A\.env(\.[\w-]+)?\z/
    ENV_TEMPLATE_RE = /\.(example|sample|template|dist|defaults|schema|test|ci)\z/

    def check_committed_env_files
      inventory.each do |path, _size|
        base = File.basename(path)
        next unless base.match?(ENV_FILE_RE) && !base.match?(ENV_TEMPLATE_RE)
        next if path.split("/").any? { |seg| FileSet::IGNORED_DIRS.include?(seg) }

        secret_line = nil
        repo_files.read(path).to_s.each_line.with_index(1) do |text, line|
          m = text.chomp.match(/\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/)
          next unless m && m[1].upcase.match?(SECRET_KEY_RE)

          value = m[2].strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
          next if value.empty? || value.match?(/\A(changeme|change_me|xxx+|your[-_].*|<.*>|\$\{.*\}|placeholder|todo)\z/i)

          secret_line = line
          break
        end

        if secret_line
          add("committed_secrets", "#{path} is committed and contains secret values.",
              file: path, line: secret_line,
              fix: "Remove it from git, rotate the exposed credentials, add it to .gitignore and set the values as project secrets.")
        else
          add("committed_env_file", "#{path} is committed; env files usually hold secrets and are ignored by the generated .dockerignore.",
              file: path, line: nil, fix: "Remove it from git, add it to .gitignore and set values as project secrets.")
        end
      end
    end

    def check_committed_dependencies
      %w[node_modules vendor/bundle .venv venv].each do |dir|
        next unless repo_files.dir?(dir) || app_files.dir?(dir)

        path = app_files.dir?(dir) ? rel(dir) : dir
        add("committed_dependencies", "#{path}/ is committed; it bloats the build context and may contain host-specific binaries.",
            file: path, line: nil, fix: "Remove #{dir}/ from git and add it to .gitignore; dependencies are installed during the build.")
      end
    end

    def check_large_files
      total = 0
      inventory.each do |path, size|
        total += size
        next unless size >= LARGE_FILE_BYTES

        add("large_file", "#{path} is #{(size / 1024.0 / 1024).round}MB; it slows every upload and build.",
            file: path, line: nil, fix: "Remove it from the repository (use object storage or Git LFS) or add it to .dockerignore.")
      end
      return unless total >= LARGE_REPO_BYTES

      add("large_repository", "The repository checkout is #{(total / 1024.0 / 1024 / 1024).round(1)}GB.",
          fix: "Exclude data, media and build artifacts via .dockerignore or move them out of the repository.")
    end

    # ── Lockfiles ────────────────────────────────────────────────────── #

    def check_lockfiles
      return if docker?

      if node_family? || (framework == "rails" && metadata["has_package_json"])
        locks = Array(metadata["lockfiles"])
        if metadata["workspace_lockfile"]
          add("workspace_lockfile", "#{app_dir} uses the workspace-root #{metadata['lockfile']}, which is outside its build context; the build installs without a lockfile.",
              file: rel("package.json"), line: nil,
              fix: "Commit a Dockerfile that builds from the repo root (e.g. turbo prune / pnpm deploy), or give the app its own lockfile.")
        elsif !metadata["has_lock_file"] && framework != "bun"
          add("lockfile_missing", "No JS lockfile; dependency versions float on every build.",
              file: rel("package.json"), line: nil,
              fix: "Run your package manager's install locally and commit the lockfile (package-lock.json, yarn.lock, pnpm-lock.yaml).")
        end
        if locks.size > 1
          add("multiple_lockfiles", "Several lockfiles are committed (#{locks.join(', ')}); Anchor uses #{metadata['lockfile']}.",
              file: rel(locks.last), line: nil, fix: "Delete the lockfiles of package managers you don't use.")
        end
      end

      if framework == "rails" && metadata["bundler_lock"] == false
        add("lockfile_missing", "Gemfile.lock is not committed; gem versions float and BUNDLE_DEPLOYMENT cannot be used.",
            file: rel("Gemfile"), line: nil, fix: "Run `bundle lock --add-platform x86_64-linux` and commit Gemfile.lock.")
      end

      if framework == "go" && metadata["has_requires"] && !metadata["has_go_sum"]
        add("go_sum_missing", "go.mod lists requirements but go.sum is missing; `go build` fails with \"missing go.sum entry\".",
            file: rel("go.mod"), line: nil, fix: "Run `go mod tidy` and commit go.sum.")
      end

      if metadata["package_manager"] == "pipenv" && !app_files.exist?("Pipfile.lock")
        add("lockfile_missing", "Pipfile has no Pipfile.lock; dependency versions float on every build.",
            file: rel("Pipfile"), line: nil, fix: "Run `pipenv lock` and commit Pipfile.lock.")
      end
    end

    def check_go_main
      return unless framework == "go" && !docker?
      return unless metadata["has_main"] == false

      add("go_no_main_package", "No `package main` with `func main()` was found; there is nothing to build into a binary.",
          file: rel("go.mod"), line: nil, fix: "Add a main package (e.g. cmd/server/main.go) or commit a Dockerfile.")
    end

    def check_python_server
      return if docker? || metadata["procfile_web"]

      missing = case framework
      when "fastapi" then metadata["has_uvicorn"] ? nil : "uvicorn"
      when "flask", "django" then metadata["has_gunicorn"] ? nil : "gunicorn"
      end
      return unless missing

      add("python_server_missing", "#{missing} is not in your dependencies; Anchor installs the latest version into the image.",
          file: nil, line: nil, fix: "Add a pinned #{missing} to your dependencies for reproducible builds.")
    end

    # ── Runtime versions ─────────────────────────────────────────────── #

    VERSION_FILES = {
      "node"   => %w[.nvmrc .node-version],
      "ruby"   => %w[.ruby-version],
      "python" => %w[.python-version runtime.txt]
    }.freeze

    def runtime_language
      return "node" if node_family?

      { "rails" => "ruby", "fastapi" => "python", "flask" => "python", "django" => "python",
        "python" => "python", "go" => "go" }[framework]
    end

    def check_runtime_version
      lang = runtime_language
      return unless lang && !docker?

      Array(VERSION_FILES[lang]).each do |f|
        raw = app_files.read(f)
        next if raw.nil? || raw.strip.empty? || RuntimeVersions.clean(raw)
        next if lang == "node" && raw.strip.match?(%r{\A(lts/\S+|node|stable|latest)\z}i)

        add("runtime_version_unrecognized", "#{f} contains #{raw.strip[0, 40].inspect}, which is not a version; Anchor uses #{version_for(lang)}.",
            file: rel(f), line: 1, fix: "Put a plain version number (e.g. #{RuntimeVersions::DEFAULTS[lang]}) in #{f}.")
      end

      version = version_for(lang)
      return unless version

      source = version_source(lang)
      if RuntimeVersions.older_than?(version, RuntimeVersions::UNSUPPORTED_BELOW.fetch(lang))
        add("runtime_version_unsupported", "#{lang.capitalize} #{version} is too old for Anchor's base images (minimum #{RuntimeVersions::UNSUPPORTED_BELOW[lang]}).",
            file: source, line: source ? 1 : nil,
            fix: "Upgrade to #{lang.capitalize} #{RuntimeVersions::DEFAULTS[lang]} or commit your own Dockerfile.")
      elsif RuntimeVersions.older_than?(version, RuntimeVersions::EOL_BELOW.fetch(lang))
        add("runtime_version_eol", "#{lang.capitalize} #{version} is end-of-life and no longer receives security fixes.",
            file: source, line: source ? 1 : nil,
            fix: "Upgrade to #{lang.capitalize} #{RuntimeVersions::DEFAULTS[lang]}.")
      end
    end

    def version_for(lang)
      { "node" => metadata["node_version"], "ruby" => metadata["ruby_version"],
        "python" => metadata["python_version"], "go" => metadata["go_version"] }[lang]
    end

    def version_source(lang)
      source = lang == "node" ? metadata["node_version_source"] : nil
      source ||= Array(VERSION_FILES[lang]).find { |f| app_files.exist?(f) }&.then { |f| rel(f) }
      source ||= rel("go.mod") if lang == "go"
      source
    end
  end
end
