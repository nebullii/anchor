module Analysis
  # Works out what kind of app lives in ONE directory of a repository.
  #
  # Every language probe parses its manifests properly (see Analysis::Parsers)
  # and produces a Candidate carrying a confidence score (0..1) and evidence
  # ("file:line — reason") for why it thinks so. The best candidate wins;
  # ties are broken by PREFERENCE so results are deterministic.
  #
  #   Analysis::DirectoryDetector.new("/tmp/repo", "apps/web").call
  #   # => #<Candidate framework="nextjs" confidence=0.95 evidence=[...] ...>
  #
  # Returns nil when the directory contains nothing deployable.
  class DirectoryDetector
    Candidate = Struct.new(:framework, :runtime, :port, :confidence, :evidence,
                           :metadata, :root_dir, :errors, keyword_init: true)

    PREFERENCE = %w[docker rails nextjs bun node django fastapi flask python go elixir static].freeze

    DEFAULT_PORTS = {
      "docker" => 8080, "rails" => 3000, "nextjs" => 3000, "bun" => 3000, "node" => 3000,
      "django" => 8000, "fastapi" => 8000, "flask" => 5000, "python" => 8000,
      "go" => 8080, "elixir" => 4000, "static" => 8080
    }.freeze

    NODE_SERVER_DEPS = %w[express fastify koa @hapi/hapi hapi @nestjs/core hono restify polka @adonisjs/core].freeze
    STATIC_BUILDERS  = { "vite" => "dist", "react-scripts" => "build", "astro" => "dist", "@angular/cli" => "dist", "parcel" => "dist" }.freeze

    NODE_LOCKFILES = {
      "bun.lock" => "bun", "bun.lockb" => "bun", "pnpm-lock.yaml" => "pnpm",
      "yarn.lock" => "yarn", "package-lock.json" => "npm", "npm-shrinkwrap.json" => "npm"
    }.freeze

    attr_reader :files, :root_dir

    def initialize(repo_root, root_dir = ".", workspace_root: nil)
      @repo_root = repo_root
      @root_dir  = root_dir.presence || "."
      @files     = FileSet.new(root_dir == "." ? repo_root : File.join(repo_root, root_dir))
      @workspace_root = workspace_root
    end

    def call
      candidates.max_by { |c| [ c.confidence, -PREFERENCE.index(c.framework).to_i ] }
    end

    # All plausible interpretations of this directory, unsorted.
    def candidates
      @candidates ||= [ docker_candidate, *language_candidates ].compact
    end

    # The best non-Docker interpretation — what the app *is* even when the
    # repo ships its own Dockerfile. Used by preflight rules.
    def underlying
      language_candidates.max_by { |c| [ c.confidence, -PREFERENCE.index(c.framework).to_i ] }
    end

    private

    def language_candidates
      @language_candidates ||= [
        ruby_candidate, node_candidate, python_candidate,
        go_candidate, elixir_candidate, static_candidate
      ].compact
    end

    def build(framework, confidence:, evidence:, metadata:, runtime:, port: nil, errors: [])
      Candidate.new(
        framework:  framework,
        runtime:    runtime,
        port:       port || DEFAULT_PORTS.fetch(framework),
        confidence: confidence.round(2),
        evidence:   evidence,
        metadata:   metadata,
        root_dir:   @root_dir,
        errors:     errors
      )
    end

    # Evidence for a path relative to this app directory.
    def ev(file, line, reason)
      repo_ev(rel(file), line, reason)
    end

    # Evidence for a path already relative to the repository root.
    def repo_ev(file, line, reason)
      { "file" => file, "line" => line, "reason" => reason }
    end

    # Evidence paths are relative to the repository root, not the app dir.
    def rel(file)
      @root_dir == "." ? file : File.join(@root_dir, file)
    end

    def parse_error(file, error)
      { "file" => rel(file), "line" => error.line, "message" => error.message }
    end

    # ── Docker ───────────────────────────────────────────────────────── #

    def docker_candidate
      return nil unless files.exist?("Dockerfile")

      dockerfile = Parsers::Dockerfile.parse(files.read("Dockerfile").to_s)
      exposed    = dockerfile.exposed_ports
      evidence   = [ ev("Dockerfile", 1, "repository provides its own Dockerfile") ]
      evidence << ev("Dockerfile", exposed.first[1], "EXPOSE #{exposed.first[0]}") if exposed.any?

      build("docker",
            confidence: 0.99,
            runtime:    "custom",
            port:       exposed.first&.first,
            evidence:   evidence,
            metadata:   {
              "exposed_ports" => exposed.map(&:first),
              "dockerfile_user" => dockerfile.final_user,
              "underlying_framework" => underlying&.framework
            })
    end

    # ── Ruby / Rails ─────────────────────────────────────────────────── #

    def ruby_candidate
      return nil unless files.exist?("Gemfile") || files.exist?("Gemfile.lock")

      errors   = []
      gemfile  = Parsers::Gemfile.parse(files.read("Gemfile").to_s)
      lock     = begin
        Parsers::GemfileLock.parse(files.read("Gemfile.lock").to_s) if files.exist?("Gemfile.lock")
      rescue Parsers::ParseError => e
        errors << parse_error("Gemfile.lock", e)
        nil
      end

      evidence = []
      rails_in_lock = lock && (lock.gem?("rails") || lock.gem?("railties"))
      rails_in_gemfile = gemfile.gem?("rails") || gemfile.gem?("railties")
      return nil unless rails_in_lock || rails_in_gemfile

      confidence = 0.7
      if rails_in_lock
        name = lock.gem?("rails") ? "rails" : "railties"
        evidence << ev("Gemfile.lock", lock.line_of(name), "#{name} #{lock.version_of(name)} resolved in lockfile")
        confidence += 0.2
      end
      if rails_in_gemfile
        entry = gemfile.find("rails") || gemfile.find("railties")
        evidence << ev("Gemfile", entry.line, %(gem "#{entry.name}" declared))
        confidence += 0.1
      end
      if files.exist?("config/application.rb")
        evidence << ev("config/application.rb", files.line_of("config/application.rb", /Rails::Application/), "Rails application config")
        confidence += 0.05
      end

      ruby_version, ruby_source = detect_ruby_version(gemfile, lock)
      evidence << ev(ruby_source[0], ruby_source[1], "Ruby #{ruby_version}") if ruby_source

      node = files.exist?("package.json") ? node_tooling_metadata : {}

      build("rails",
            confidence: [ confidence, 0.99 ].min,
            runtime:    "ruby#{ruby_version[/\A\d+\.\d+/]}",
            evidence:   evidence,
            errors:     errors,
            metadata:   {
              "ruby_version"     => ruby_version,
              "ruby_version_source" => ruby_source && "#{ruby_source[0]}",
              "bundler_lock"     => !lock.nil?,
              "bundler_version"  => lock&.bundler_version,
              "rails_version"    => lock&.version_of("rails") || lock&.version_of("railties"),
              "has_puma_config"  => files.exist?("config/puma.rb"),
              "assets"           => rails_assets?(lock, gemfile),
              "has_bootsnap"     => lock ? lock.gem?("bootsnap") : gemfile.gem?("bootsnap"),
              "database_adapter" => rails_db_gem(lock, gemfile),
              "has_package_json" => files.exist?("package.json")
            }.merge(node.slice("package_manager", "lockfile", "node_version", "yarn_berry")).compact)
    end

    def detect_ruby_version(gemfile, lock)
      if (v = RuntimeVersions.clean(files.read(".ruby-version")))
        return [ v, [ ".ruby-version", 1 ] ]
      end
      if gemfile.ruby_file && (v = RuntimeVersions.clean(files.read(gemfile.ruby_file)))
        return [ v, [ gemfile.ruby_file, 1 ] ]
      end
      if gemfile.ruby_requirement && (v = gemfile.ruby_requirement[/\d+\.\d+(\.\d+)?/])
        return [ v, [ "Gemfile", gemfile.ruby_line ] ]
      end
      if lock&.ruby_version
        return [ lock.ruby_version, [ "Gemfile.lock", files.line_of("Gemfile.lock", "RUBY VERSION") ] ]
      end
      if (tv = tool_versions["ruby"])
        return [ tv, [ ".tool-versions", files.line_of(".tool-versions", /\Aruby\s/) ] ]
      end

      [ RuntimeVersions::DEFAULTS["ruby"], nil ]
    end

    def rails_assets?(lock, gemfile)
      %w[sprockets-rails propshaft sprockets].any? { |g| lock ? lock.gem?(g) : gemfile.gem?(g) }
    end

    def rails_db_gem(lock, gemfile)
      { "pg" => "postgresql", "mysql2" => "mysql", "trilogy" => "mysql", "sqlite3" => "sqlite" }
        .find { |g, _| lock ? lock.gem?(g) : gemfile.gem?(g) }&.last
    end

    # ── Node / Bun / Next.js / static builds ─────────────────────────── #

    def node_candidate
      return nil unless files.exist?("package.json")

      pkg = begin
        Parsers::PackageJson.parse(files.read("package.json").to_s)
      rescue Parsers::ParseError => e
        return build("node", confidence: 0.3, runtime: "node#{RuntimeVersions::DEFAULTS['node']}",
                     evidence: [ ev("package.json", nil, "package.json present but unparseable") ],
                     errors:   [ parse_error("package.json", e) ],
                     metadata: { "node_version" => RuntimeVersions::DEFAULTS["node"], "parse_error" => e.message,
                                 "has_lock_file" => false, "package_manager" => "npm" })
      end

      meta     = node_tooling_metadata(pkg)
      evidence = []
      evidence << repo_ev(meta["lockfile_path"], nil, "#{meta['package_manager']} lockfile") if meta["lockfile_path"]
      evidence << repo_ev(meta["node_version_source"], meta["node_version_line"], "Node #{meta['node_version']}") if meta["node_version_source"]
      meta = meta.except("node_version_line", "lockfile_path")

      if pkg.dependency?("next")
        evidence.unshift(ev("package.json", pkg.line_for_dependency("next"), "next #{pkg.all_dependencies['next']} dependency"))
        return build("nextjs", confidence: 0.95, runtime: "node#{major(meta['node_version'])}",
                     evidence: evidence, metadata: meta.merge(next_metadata))
      end

      if meta["package_manager"] == "bun"
        evidence.unshift(ev("package.json", pkg.line_for("packageManager"), "packageManager is bun")) unless meta["lockfile"]
        return build("bun", confidence: 0.9, runtime: "bun#{major(meta['bun_version'] || '1')}",
                     evidence: evidence.uniq, metadata: meta)
      end

      framework_detail, detail_dep = node_framework_detail(pkg)
      if framework_detail
        evidence.unshift(ev("package.json", pkg.line_for_dependency(detail_dep), "#{detail_dep} dependency"))
      end

      builder = STATIC_BUILDERS.keys.find { |d| pkg.dependency?(d) }
      if builder && framework_detail.nil? && pkg.script("build") && !server_start?(pkg)
        return build("static", confidence: 0.85, runtime: "nginx",
                     evidence: [ ev("package.json", pkg.line_for_dependency(builder), "#{builder} static build, no server"),
                                ev("package.json", pkg.line_for_script("build"), "build script") ] + evidence,
                     metadata: meta.merge("build_tool" => builder, "output_dir" => static_output_dir(builder)))
      end

      # No start script and no server framework usually means a library.
      confidence = framework_detail || meta["start_script"] ? 0.6 : 0.5
      confidence += 0.25 if framework_detail
      confidence += 0.1 if meta["start_script"] || (meta["main"] && files.exist?(meta["main"]))
      if meta["start_script"]
        evidence << ev("package.json", pkg.line_for_script("start"), "start script: #{meta['start_script']}")
      end

      build("node", confidence: [ confidence, 0.95 ].min, runtime: "node#{major(meta['node_version'])}",
            port: hard_coded_start_port(meta["start_script"]),
            evidence: evidence, metadata: meta.merge("node_framework" => framework_detail).compact)
    end

    # Package manager, lockfile and Node version for this directory. When the
    # app sits inside a JS workspace, the lockfile may live at the workspace
    # root instead.
    def node_tooling_metadata(pkg = nil)
      pkg ||= (Parsers::PackageJson.parse(files.read("package.json").to_s) rescue nil)
      pm_field = pkg&.package_manager

      lockfile, pm = NODE_LOCKFILES.find { |name, _| files.exist?(name) }
      lockfile_path = lockfile
      workspace_lock = false
      if lockfile.nil? && @workspace_root
        ws_files = FileSet.new(@workspace_root == "." ? @repo_root : File.join(@repo_root, @workspace_root))
        lockfile, pm = NODE_LOCKFILES.find { |name, _| ws_files.exist?(name) }
        if lockfile
          workspace_lock = true
          lockfile_path  = @workspace_root == "." ? lockfile : File.join(@workspace_root, lockfile)
        end
      end
      pm = pm_field[0] if pm_field && %w[npm yarn pnpm bun].include?(pm_field[0])
      pm ||= "npm"

      node_version, source, line = detect_node_version(pkg)
      all_locks = NODE_LOCKFILES.keys.select { |name| files.exist?(name) }

      {
        "node_version"        => node_version,
        "node_version_source" => source && rel(source),
        "node_version_line"   => line,
        "package_manager"     => pm,
        "package_manager_version" => pm_field && pm_field[0] == pm ? pm_field[1] : nil,
        "lockfile"            => lockfile,
        "lockfile_path"       => lockfile_path && (workspace_lock ? lockfile_path : rel(lockfile_path)),
        "lockfiles"           => all_locks,
        "workspace_lockfile"  => workspace_lock,
        "has_lock_file"       => !lockfile.nil?,
        "yarn_berry"          => pm == "yarn" && yarn_berry?(pm_field),
        "bun_version"         => pm == "bun" ? pm_field&.dig(1) : nil,
        "start_script"        => pkg&.script("start"),
        "build_script"        => pkg&.script("build"),
        "main"                => pkg&.main
      }.compact
    end

    def detect_node_version(pkg)
      %w[.nvmrc .node-version].each do |f|
        v = RuntimeVersions.clean(files.read(f))
        return [ v, f, 1 ] if v
      end
      if (tv = tool_versions["nodejs"] || tool_versions["node"])
        return [ tv, ".tool-versions", files.line_of(".tool-versions", /\Anode/) ]
      end
      if pkg&.engines_node && (line = RuntimeVersions.node_line_for(pkg.engines_node))
        return [ line, "package.json", pkg.line_for(%("node")) ]
      end

      [ RuntimeVersions::DEFAULTS["node"], nil, nil ]
    end

    def yarn_berry?(pm_field)
      return pm_field[1].to_i >= 2 if pm_field && pm_field[0] == "yarn"
      return true if files.exist?(".yarnrc.yml")

      files.read("yarn.lock").to_s.include?("__metadata:")
    end

    def node_framework_detail(pkg)
      return [ "nuxt", "nuxt" ] if pkg.dependency?("nuxt")

      remix = pkg.all_dependencies.keys.sort.find { |k| k.start_with?("@remix-run/") }
      return [ "remix", remix ] if remix
      return [ "sveltekit", "@sveltejs/kit" ] if pkg.dependency?("@sveltejs/kit")
      return [ "astro", "astro" ] if pkg.dependency?("astro") && pkg.all_dependencies.keys.any? { |k| k.start_with?("@astrojs/node") }

      server = NODE_SERVER_DEPS.find { |d| pkg.dependencies.key?(d) }
      server ? [ server.delete_prefix("@").split("/").first == "nestjs" ? "nestjs" : server.split("/").last, server ] : nil
    end

    def server_start?(pkg)
      start = pkg.script("start").to_s
      return false if start.empty?

      !start.match?(/\A\s*(vite\s+preview|serve\b|npx serve|react-scripts start|astro preview)/)
    end

    def static_output_dir(builder)
      if builder == "vite" && (cfg = files.read("vite.config.ts") || files.read("vite.config.js") || files.read("vite.config.mjs"))
        custom = cfg[/outDir\s*:\s*["']([^"']+)["']/, 1]
        return custom if custom && !custom.include?("..")
      end
      STATIC_BUILDERS[builder]
    end

    def next_metadata
      config_name = %w[next.config.js next.config.mjs next.config.ts next.config.cjs].find { |f| files.exist?(f) }
      config = config_name ? files.read(config_name).to_s : ""
      {
        "next_config"     => config_name,
        "next_standalone" => config.match?(/output\s*:\s*["']standalone["']/),
        "next_export"     => config.match?(/output\s*:\s*["']export["']/),
        "has_public_dir"  => files.dir?("public")
      }.compact
    end

    def hard_coded_start_port(start_script)
      m = start_script.to_s.match(/\bPORT=(\d+)|--port[= ](\d+)|-p (\d+)/)
      m ? m.captures.compact.first.to_i : nil
    end

    def major(version)
      version.to_s[/\A\d+/] || version.to_s
    end

    # ── Python ───────────────────────────────────────────────────────── #

    def python_candidate
      manifests = %w[requirements.txt pyproject.toml Pipfile uv.lock setup.py manage.py].select { |f| files.exist?(f) }
      return nil if manifests.empty?

      deps, errors, py_meta = python_dependencies
      evidence = []

      framework, confidence =
        if files.exist?("manage.py")
          evidence << ev("manage.py", files.line_of("manage.py", "DJANGO_SETTINGS_MODULE") || 1, "Django manage.py")
          [ "django", deps["django"] ? 0.95 : 0.85 ]
        elsif deps["fastapi"] then [ "fastapi", 0.9 ]
        elsif deps["flask"]   then [ "flask", 0.9 ]
        elsif deps["django"]  then [ "django", 0.85 ]
        else [ "python", 0.6 ]
        end

      dep_name = framework == "python" ? nil : framework
      evidence << ev(deps[dep_name][0], deps[dep_name][1], "#{dep_name} dependency") if dep_name && deps[dep_name]
      evidence << ev(manifests.first, nil, "Python manifest") if evidence.empty?

      py_version, py_source = detect_python_version(py_meta)
      evidence << ev(py_source[0], py_source[1], "Python #{py_version}") if py_source

      metadata = {
        "python_version"   => py_version,
        "package_manager"  => python_package_manager,
        "has_requirements" => files.exist?("requirements.txt"),
        "has_pyproject"    => files.exist?("pyproject.toml"),
        "has_procfile"     => files.exist?("Procfile"),
        "procfile_web"     => procfile_web,
        "has_gunicorn"     => deps.key?("gunicorn"),
        "has_uvicorn"      => deps.key?("uvicorn"),
        "dependencies"     => deps.keys.sort
      }

      case framework
      when "fastapi"
        entry, var = find_python_app(/(\w+)\s*=\s*FastAPI\(/, %w[main.py app.py server.py api.py app/main.py src/main.py])
        metadata["entry_point"] = entry || "main.py"
        metadata["asgi_app"]    = "#{python_module(entry || 'main.py')}:#{var || 'app'}"
      when "flask"
        entry, var = find_python_app(/(\w+)\s*=\s*Flask\(/, %w[app.py main.py wsgi.py server.py application.py app/__init__.py])
        metadata["entry_point"] = entry || detect_python_entry
        metadata["wsgi_app"]    = "#{python_module(entry || 'app.py')}:#{var || 'app'}"
      when "django"
        settings = files.read("manage.py").to_s[/DJANGO_SETTINGS_MODULE['"]\s*,\s*['"]([^'"]+)/, 1]
        metadata["settings_module"] = settings
        metadata["wsgi_module"]     = settings&.sub(/\.settings.*/, ".wsgi")
        metadata["collectstatic"]   = settings_file(settings).then { |f| f && files.read(f).to_s.match?(/^\s*STATIC_ROOT\s*=/) }
      else
        metadata["entry_point"] = detect_python_entry
      end

      build(framework, confidence: confidence, runtime: "python#{py_version[/\A\d+\.\d+/]}",
            evidence: evidence, errors: errors, metadata: metadata.compact)
    end

    # { "fastapi" => ["requirements.txt", 3], ... } plus parse errors and
    # the requires-python style constraints we saw.
    def python_dependencies
      deps   = {}
      errors = []
      meta   = {}
      add = ->(name, file, line) { deps[name] ||= [ file, line ] }

      if (content = files.read("requirements.txt"))
        Parsers::Requirements.parse(content).each { |r| add.call(r.name, "requirements.txt", r.line) }
      end

      if (content = files.read("pyproject.toml"))
        begin
          toml = Parsers::Toml.parse(content)
          project = toml["project"].is_a?(Hash) ? toml["project"] : {}
          Array(project["dependencies"]).each do |d|
            name, = Parsers::Requirements.parse_pep508(d)
            add.call(name, "pyproject.toml", line_in(content, d)) if name
          end
          poetry = toml.dig("tool", "poetry", "dependencies")
          if poetry.is_a?(Hash)
            poetry.each_key do |k|
              next if k == "python"

              add.call(Parsers::Requirements.normalize(k), "pyproject.toml", line_in(content, /^\s*"?#{Regexp.escape(k)}"?\s*=/))
            end
            meta["poetry_python"] = poetry["python"] if poetry["python"].is_a?(String)
          end
          meta["requires_python"] = project["requires-python"] if project["requires-python"].is_a?(String)
        rescue Parsers::ParseError => e
          errors << parse_error("pyproject.toml", e)
          content.scan(/^\s*"?([A-Za-z][\w.-]*)/).flatten.each { |n| add.call(Parsers::Requirements.normalize(n), "pyproject.toml", nil) if %w[fastapi flask django].include?(n.downcase) }
        end
      end

      if (content = files.read("Pipfile"))
        begin
          toml = Parsers::Toml.parse(content)
          (toml["packages"].is_a?(Hash) ? toml["packages"] : {}).each_key do |k|
            add.call(Parsers::Requirements.normalize(k), "Pipfile", line_in(content, /^\s*"?#{Regexp.escape(k)}"?\s*=/))
          end
          meta["pipfile_python"] = toml.dig("requires", "python_version")
        rescue Parsers::ParseError => e
          errors << parse_error("Pipfile", e)
        end
      end

      if (content = files.read("uv.lock"))
        begin
          toml = Parsers::Toml.parse(content)
          Array(toml["package"]).each do |p|
            next unless p.is_a?(Hash) && p["name"].is_a?(String)

            add.call(Parsers::Requirements.normalize(p["name"]), "uv.lock", line_in(content, %(name = "#{p['name']}")))
          end
          meta["uv_requires_python"] = toml["requires-python"] if toml["requires-python"].is_a?(String)
        rescue Parsers::ParseError => e
          errors << parse_error("uv.lock", e)
        end
      end

      if (content = files.read("setup.py"))
        content.scan(/["']([A-Za-z][\w.-]*)\s*[<>=~!]?[^"']*["']/).flatten.each do |n|
          norm = Parsers::Requirements.normalize(n)
          add.call(norm, "setup.py", line_in(content, n)) if %w[fastapi flask django gunicorn uvicorn].include?(norm)
        end
      end

      [ deps, errors, meta ]
    end

    def detect_python_version(py_meta)
      if (v = RuntimeVersions.clean(files.read(".python-version")))
        return [ v.split(".").first(2).join("."), [ ".python-version", 1 ] ]
      end
      if (v = RuntimeVersions.clean(files.read("runtime.txt")))
        return [ v.split(".").first(2).join("."), [ "runtime.txt", 1 ] ]
      end
      if (tv = tool_versions["python"])
        return [ tv.split(".").first(2).join("."), [ ".tool-versions", files.line_of(".tool-versions", /\Apython/) ] ]
      end
      {
        "requires_python"    => [ "pyproject.toml", /requires-python/ ],
        "poetry_python"      => [ "pyproject.toml", /^\s*python\s*=/ ],
        "pipfile_python"     => [ "Pipfile", /python_version/ ],
        "uv_requires_python" => [ "uv.lock", /requires-python/ ]
      }.each do |key, (file, pattern)|
        next unless py_meta[key].is_a?(String)

        line = RuntimeVersions.python_line_for(py_meta[key])
        return [ line, [ file, files.line_of(file, pattern) ] ] if line
      end

      [ RuntimeVersions::DEFAULTS["python"], nil ]
    end

    def python_package_manager
      return "uv"     if files.exist?("uv.lock")
      return "poetry" if files.exist?("poetry.lock")
      return "pipenv" if files.exist?("Pipfile.lock") || (files.exist?("Pipfile") && !files.exist?("requirements.txt"))
      return "pip"    if files.exist?("requirements.txt")

      files.exist?("pyproject.toml") ? "pip-pyproject" : "pip"
    end

    def find_python_app(regex, candidates)
      candidates.each do |f|
        content = files.read(f)
        next unless content && (m = content.match(regex))

        return [ f, m[1] ]
      end
      [ nil, nil ]
    end

    def python_module(path)
      path.delete_suffix(".py").delete_suffix("/__init__").tr("/", ".")
    end

    def detect_python_entry
      %w[main.py app.py wsgi.py manage.py server.py].find { |entry| files.exist?(entry) }
    end

    def settings_file(settings_module)
      return nil unless settings_module

      base = settings_module.tr(".", "/")
      [ "#{base}.py", "#{base}/__init__.py", "#{base}/base.py", "#{base}/production.py" ].find { |f| files.exist?(f) }
    end

    def procfile_web
      files.read("Procfile").to_s.each_line do |line|
        m = line.match(/\A\s*web\s*:\s*(.+)\z/)
        return m[1].strip if m
      end
      nil
    end

    # ── Go ───────────────────────────────────────────────────────────── #

    def go_candidate
      return nil unless files.exist?("go.mod")

      errors = []
      mod = begin
        Parsers::GoMod.parse(files.read("go.mod").to_s)
      rescue Parsers::ParseError => e
        errors << parse_error("go.mod", e)
        nil
      end

      main_pkg, main_file = find_go_main
      version = mod&.go_minor || RuntimeVersions::DEFAULTS["go"]
      if mod&.toolchain && RuntimeVersions.compare(mod.toolchain, version) > 0
        version = mod.toolchain[/\A\d+\.\d+/]
      end

      evidence = [ ev("go.mod", mod&.go_line || 1, mod&.go_version ? "go #{mod.go_version} directive" : "go.mod present") ]
      evidence << ev(main_file, files.line_of(main_file, /func main\(\)/), "main package") if main_file

      build("go", confidence: main_pkg ? 0.95 : 0.75, runtime: "go#{version}",
            evidence: evidence, errors: errors,
            metadata: {
              "go_version"      => version,
              "go_version_full" => mod&.go_version,
              "toolchain"       => mod&.toolchain,
              "module_name"     => mod&.module_path,
              "has_main"        => !main_pkg.nil?,
              "main_package"    => main_pkg,
              "has_go_sum"      => files.exist?("go.sum"),
              "has_requires"    => mod ? mod.requires.any? : false
            }.compact)
    end

    # Finds the main package: repo root first, then cmd/<name>, then any dir.
    def find_go_main
      go_files = files.files(extensions: [ ".go" ], limit: 2_000).reject { |f| f.end_with?("_test.go") }
      mains = go_files.select do |f|
        content = files.read(f).to_s
        content.match?(/^package main\b/) && content.match?(/^func main\(\)/)
      end
      return [ nil, nil ] if mains.empty?

      best = mains.min_by do |f|
        dir = File.dirname(f)
        [ dir == "." ? 0 : (dir.start_with?("cmd/") ? 1 : 2), dir.count("/"), f ]
      end
      dir = File.dirname(best)
      [ dir == "." ? "." : "./#{dir}", best ]
    end

    # ── Elixir ───────────────────────────────────────────────────────── #

    def elixir_candidate
      return nil unless files.exist?("mix.exs")

      errors = []
      mix = begin
        Parsers::MixExs.parse(files.read("mix.exs").to_s)
      rescue Parsers::ParseError => e
        errors << parse_error("mix.exs", e)
        Parsers::MixExs.parse("")
      end

      evidence = [ ev("mix.exs", files.line_of("mix.exs", /\bapp:/) || 1, "Mix project#{" :#{mix.app_name}" if mix.app_name}") ]
      evidence << ev("mix.exs", mix.line_of("phoenix"), "phoenix dependency") if mix.dep?("phoenix")
      elixir = RuntimeVersions.elixir_line_for(mix.elixir_requirement)

      build("elixir", confidence: mix.dep?("phoenix") ? 0.95 : 0.8, runtime: "elixir#{elixir}",
            evidence: evidence, errors: errors,
            metadata: {
              "mix_project"    => mix.app_name,
              "has_phoenix"    => mix.dep?("phoenix"),
              "elixir_version" => elixir,
              "has_mix_lock"   => files.exist?("mix.lock"),
              "has_assets"     => files.dir?("assets"),
              "has_config"     => files.dir?("config")
            }.compact)
    end

    # ── Plain static site ────────────────────────────────────────────── #

    def static_candidate
      server_manifests = %w[package.json requirements.txt pyproject.toml Pipfile setup.py Gemfile go.mod mix.exs manage.py]
      return nil if server_manifests.any? { |f| files.exist?(f) }

      index = %w[index.html public/index.html dist/index.html docs/index.html].find { |f| files.exist?(f) }
      return nil unless index

      output_dir = File.dirname(index)
      build("static", confidence: index == "index.html" ? 0.6 : 0.5, runtime: "nginx",
            evidence: [ ev(index, 1, "static index.html with no server-side manifest") ],
            metadata: { "output_dir" => output_dir == "." ? nil : output_dir }.compact)
    end

    # ── Shared ───────────────────────────────────────────────────────── #

    # asdf/mise .tool-versions: "nodejs 20.11.1"
    def tool_versions
      @tool_versions ||= files.read(".tool-versions").to_s.each_line.each_with_object({}) do |line, h|
        name, version = line.strip.split(/\s+/)
        v = RuntimeVersions.clean(version)
        h[name] = v if name && v
      end
    end

    def line_in(content, pattern)
      content.each_line.with_index(1) do |l, n|
        return n if pattern.is_a?(Regexp) ? l.match?(pattern) : l.include?(pattern)
      end
      nil
    end
  end
end
