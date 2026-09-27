require "rails_helper"

# End-to-end checks over the tiny, realistic repositories in
# spec/fixtures/repos: detection, generated Dockerfiles (golden files) and
# preflight findings.
#
# Regenerate golden files after an intentional template change with:
#   UPDATE_GOLDEN=1 bundle exec rspec spec/services/fixture_repos_spec.rb
# and review the diff before committing.
RSpec.describe "Fixture repositories" do
  fixtures_root = Rails.root.join("spec/fixtures/repos")

  # Copies a fixture into a temp dir (without golden files) so generation
  # never writes into the source tree.
  def with_fixture(root, name)
    dir = Dir.mktmpdir("fixture-#{name}-")
    FileUtils.cp_r(File.join(root, name, "."), dir)
    Dir.glob(File.join(dir, "expected.*")).each { |f| FileUtils.rm_f(f) }
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  DETECTIONS = {
    "rails_app"     => { framework: "rails",   runtime: "ruby3.3",   port: 3000, meta: { "ruby_version" => "3.3.6", "rails_version" => "8.0.2", "bundler_lock" => true, "database_adapter" => "postgresql" } },
    "nextjs_app"    => { framework: "nextjs",  runtime: "node22",    port: 3000, meta: { "package_manager" => "npm", "next_standalone" => true, "has_public_dir" => true } },
    "express_yarn"  => { framework: "node",    runtime: "node20",    port: 3000, meta: { "node_version" => "20.11.1", "package_manager" => "yarn", "node_framework" => "express" } },
    "nuxt_pnpm"     => { framework: "node",    runtime: "node22",    port: 3000, meta: { "package_manager" => "pnpm", "node_framework" => "nuxt" } },
    "vite_spa"      => { framework: "static",  runtime: "nginx",     port: 8080, meta: { "build_tool" => "vite", "output_dir" => "dist" } },
    "bun_app"       => { framework: "bun",     runtime: "bun1",      port: 3000, meta: { "lockfile" => "bun.lock" } },
    "fastapi_uv"    => { framework: "fastapi", runtime: "python3.12", port: 8000, meta: { "package_manager" => "uv", "asgi_app" => "app.main:api", "has_uvicorn" => true } },
    "flask_pip"     => { framework: "flask",   runtime: "python3.11", port: 5000, meta: { "package_manager" => "pip", "wsgi_app" => "app:application", "has_gunicorn" => true } },
    "django_poetry" => { framework: "django",  runtime: "python3.12", port: 8000, meta: { "package_manager" => "poetry", "settings_module" => "mysite.settings", "collectstatic" => true } },
    "go_service"    => { framework: "go",      runtime: "go1.23",    port: 8080, meta: { "main_package" => "./cmd/server", "go_version_full" => "1.23.4" } },
    "phoenix_app"   => { framework: "elixir",  runtime: "elixir1.18", port: 4000, meta: { "mix_project" => "hello", "has_phoenix" => true } },
    "static_site"   => { framework: "static",  runtime: "nginx",     port: 8080, meta: {} },
    "docker_custom" => { framework: "docker",  runtime: "custom",    port: 9000, meta: { "exposed_ports" => [ 9000 ], "underlying_framework" => "python" } },
    "monorepo_turbo" => { framework: "nextjs", runtime: "node22",    port: 3000, root_dir: "apps/web", meta: { "workspace_lockfile" => true } }
  }.freeze

  describe "detection" do
    DETECTIONS.each do |name, expected|
      it "detects #{name} as #{expected[:framework]}" do
        detection = FrameworkDetector.new(fixtures_root.join(name).to_s, nil).call

        expect(detection.framework).to eq(expected[:framework])
        expect(detection.runtime).to eq(expected[:runtime])
        expect(detection.port).to eq(expected[:port])
        expect(detection.app_dir).to eq(expected[:root_dir] || ".")
        expect(detection.metadata).to include(expected[:meta])
        expect(detection.confidence).to be_between(0.5, 1.0)
        expect(detection.evidence).to all(include("reason"))
      end
    end

    it "points evidence at real file:line locations" do
      detection = FrameworkDetector.new(fixtures_root.join("rails_app").to_s, nil).call
      lock = detection.evidence.find { |e| e["file"] == "Gemfile.lock" }

      expect(lock["line"]).to be_a(Integer)
      line = File.readlines(fixtures_root.join("rails_app/Gemfile.lock"))[lock["line"] - 1]
      expect(line).to include("rails (8.0.2)")
    end

    it "reports every app in a monorepo as a candidate" do
      detection = FrameworkDetector.new(fixtures_root.join("monorepo_turbo").to_s, nil).call
      roots = detection.candidates.map { |c| c["root_dir"] }

      expect(roots).to contain_exactly("apps/api", "apps/web", "packages/ui")
      expect(detection.evidence.map { |e| e["reason"] }).to include(a_string_matching(/candidate apps found/))
    end

    it "honours an explicit root_dir in a monorepo" do
      detection = FrameworkDetector.new(fixtures_root.join("monorepo_turbo").to_s, nil, root_dir: "apps/api").call

      expect(detection.framework).to eq("node")
      expect(detection.metadata["node_framework"]).to eq("fastify")
      expect(detection.app_dir).to eq("apps/api")
    end

    it "rejects a root_dir that escapes the repository" do
      detection = FrameworkDetector.new(fixtures_root.join("monorepo_turbo").to_s, nil, root_dir: "../../..").call

      expect(detection.framework).to eq("static")
      expect(detection.metadata["undetected"]).to be true
    end
  end

  describe "generated Dockerfiles (golden files)" do
    Dir.glob(fixtures_root.join("*/expected.Dockerfile")).sort.each do |golden|
      name = File.basename(File.dirname(golden))

      it "matches #{name}/expected.Dockerfile" do
        with_fixture(fixtures_root, name) do |dir|
          detection = FrameworkDetector.new(dir, nil).call
          path      = DockerfileGenerator.new(dir, detection).call
          content   = File.read(path)

          File.write(golden, content) if ENV["UPDATE_GOLDEN"]
          expect(content).to eq(File.read(golden))

          expect(File.dirname(path)).to eq(detection.app_path(dir))
          expect(File).to exist(File.join(detection.app_path(dir), ".dockerignore"))
        end
      end
    end

    it "is deterministic across checkouts" do
      outputs = 2.times.map do
        with_fixture(fixtures_root, "rails_app") do |dir|
          detection = FrameworkDetector.new(dir, nil).call
          File.read(DockerfileGenerator.new(dir, detection).call)
        end
      end
      expect(outputs.uniq.size).to eq(1)
    end

    it "only generates Dockerfiles that run as non-root, listen on $PORT and are multi-stage" do
      DETECTIONS.except("docker_custom").each_key do |name|
        with_fixture(fixtures_root, name) do |dir|
          detection = FrameworkDetector.new(dir, nil).call
          content   = File.read(DockerfileGenerator.new(dir, detection).call)

          expect(content).to match(/^USER \S+/), "#{name} has no USER"
          expect(content).to match(/PORT=\d+/), "#{name} does not set PORT"
          expect(content).to include("EXPOSE #{content[/PORT=(\d+)/, 1]}"), "#{name} EXPOSE disagrees with PORT"
          expect(content.scan(/^FROM /).size).to be >= 2, "#{name} is not multi-stage" unless name == "static_site"
          expect(content).not_to match(/:latest\b/), "#{name} uses a floating :latest tag"
        end
      end
    end
  end

  describe "preflight" do
    PREFLIGHT = {
      "broken_express"      => { "bind_localhost" => "error", "port_mismatch" => "error", "missing_start_script" => "error",
                                 "runtime_version_unsupported" => "error", "lockfile_missing" => "warning" },
      "broken_nextjs"       => { "nextjs_missing_build_script" => "error", "multiple_lockfiles" => "warning", "nextjs_not_standalone" => "info" },
      "broken_package_json" => { "malformed_manifest" => "error" },
      "broken_pyproject"    => { "malformed_manifest" => "error" },
      "broken_rails"        => { "malformed_manifest" => "error", "rails_no_production_database" => "error", "bind_localhost" => "error",
                                 "runtime_version_unsupported" => "error", "lockfile_missing" => "warning",
                                 "rails_secret_key_base_missing" => "warning" },
      "broken_django"       => { "django_allowed_hosts" => "error", "django_debug_enabled" => "warning", "env_var_not_set" => "warning",
                                 "python_server_missing" => "info" },
      "broken_go"           => { "go_no_main_package" => "error", "go_sum_missing" => "error", "runtime_version_eol" => "warning" },
      "broken_go_port"      => { "port_mismatch" => "error" },
      "broken_python_port"  => { "bind_localhost" => "error", "port_mismatch" => "error" },
      "monorepo_turbo"      => { "monorepo_ambiguous" => "warning", "workspace_lockfile" => "warning" }
    }.freeze

    PREFLIGHT.each do |name, expected|
      it "flags #{name}: #{expected.keys.join(', ')}" do
        path      = fixtures_root.join(name).to_s
        detection = FrameworkDetector.new(path, nil).call
        findings  = Analysis::Preflight.new(path, detection, secret_keys: []).call

        found = findings.to_h { |f| [ f[:id], f[:severity] ] }
        expect(found).to include(expected)
        expect(findings).to all(include(:id, :severity, :message, :file, :line, :fix))
      end
    end

    it "points findings at the offending file and line" do
      path     = fixtures_root.join("broken_express").to_s
      findings = Analysis::Preflight.new(path, FrameworkDetector.new(path, nil).call, secret_keys: []).call
      bind     = findings.find { |f| f[:id] == "bind_localhost" }

      expect(bind).to include(file: "app.js", line: 5)
      expect(File.readlines(File.join(path, "app.js"))[4]).to include("127.0.0.1")
    end

    %w[rails_app nextjs_app express_yarn nuxt_pnpm vite_spa bun_app flask_pip django_poetry static_site docker_custom].each do |name|
      it "raises no errors for the healthy #{name} fixture" do
        path      = fixtures_root.join(name).to_s
        detection = FrameworkDetector.new(path, nil).call
        findings  = Analysis::Preflight.new(path, detection, secret_keys: %w[SECRET_KEY_BASE DATABASE_URL STRIPE_SECRET_KEY]).call

        expect(findings.select { |f| f[:severity] == "error" }).to eq([])
      end
    end
  end
end
