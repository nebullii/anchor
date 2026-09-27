require "rails_helper"

RSpec.describe DockerfileGenerator do
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  def detection(framework:, port:, metadata: {})
    FrameworkDetector::Result.new(
      framework: framework,
      runtime:   "test",
      port:      port,
      metadata:  metadata
    )
  end

  def generate(framework:, port:, metadata: {})
    det = detection(framework: framework, port: port, metadata: metadata)
    described_class.new(repo_path, det).call
    File.read(File.join(repo_path, "Dockerfile"))
  end

  describe "#call" do
    context "when Dockerfile already exists" do
      it "does not overwrite it" do
        existing = "FROM scratch\n"
        File.write(File.join(repo_path, "Dockerfile"), existing)
        result = detection(framework: "rails", port: 3000)
        described_class.new(repo_path, result).call
        expect(File.read(File.join(repo_path, "Dockerfile"))).to eq(existing)
      end
    end

    context "rails" do
      it "generates a multi-stage Dockerfile" do
        content = generate(framework: "rails", port: 3000, metadata: { "ruby_version" => "3.3", "bundler_lock" => true })
        expect(content).to include("AS build")
        expect(content).to include("FROM ruby:3.3-slim")
        expect(content).to include("EXPOSE 3000")
        expect(content).to include("HEALTHCHECK")
        expect(content).to include("USER 1000:1000")
        expect(content).to include("puma")
      end

      it "uses Gemfile.lock when bundler_lock is true" do
        content = generate(framework: "rails", port: 3000, metadata: { "ruby_version" => "3.2", "bundler_lock" => true })
        expect(content).to include("COPY Gemfile Gemfile.lock ./")
      end

      it "omits Gemfile.lock when bundler_lock is false" do
        content = generate(framework: "rails", port: 3000, metadata: { "ruby_version" => "3.2", "bundler_lock" => false })
        expect(content).to include("COPY Gemfile ./")
      end

      it "defaults to the current ruby line when version is unknown" do
        content = generate(framework: "rails", port: 3000)
        expect(content).to include("ruby:3.4-slim")
      end
    end

    context "node" do
      it "generates a node Dockerfile with start script" do
        content = generate(framework: "node", port: 3000, metadata: { "node_version" => "20", "start_script" => "server.js", "has_lock_file" => true })
        expect(content).to include("FROM node:20-alpine")
        expect(content).to include("npm ci --omit=dev")
        expect(content).to include('["npm", "start"]')
        expect(content).to include("EXPOSE 3000")
      end

      it "uses npm install when no lockfile" do
        content = generate(framework: "node", port: 3000, metadata: { "has_lock_file" => false })
        expect(content).to include("npm install --omit=dev")
      end
    end

    context "nextjs" do
      it "generates a 3-stage Dockerfile" do
        content = generate(framework: "nextjs", port: 3000, metadata: { "node_version" => "20", "has_lock_file" => true, "next_standalone" => true })
        expect(content).to include("AS deps")
        expect(content).to include("AS builder")
        expect(content).to include("AS runner")
        expect(content).to include("server.js")
      end
    end

    context "fastapi" do
      it "generates a FastAPI Dockerfile with uvicorn" do
        content = generate(framework: "fastapi", port: 8000, metadata: { "entry_point" => "main.py" })
        expect(content).to include("python:3.12-slim")
        expect(content).to include("uvicorn")
        expect(content).to include("main:app")
        expect(content).to include("EXPOSE 8000")
      end
    end

    context "flask" do
      it "generates a Flask Dockerfile with gunicorn" do
        content = generate(framework: "flask", port: 5000, metadata: { "entry_point" => "app.py", "has_procfile" => false })
        expect(content).to include("gunicorn")
        expect(content).to include("app:app")
        expect(content).to include("EXPOSE 5000")
      end
    end

    context "django" do
      it "generates a Django Dockerfile with gunicorn" do
        content = generate(framework: "django", port: 8000, metadata: { "wsgi_module" => "myapp.wsgi" })
        expect(content).to include("gunicorn")
        expect(content).to include("myapp.wsgi")
        expect(content).to include("DJANGO_SETTINGS_MODULE")
      end
    end

    context "static" do
      it "generates an nginx Dockerfile" do
        content = generate(framework: "static", port: 80)
        expect(content).to include("nginx-unprivileged")
        expect(content).to include("/usr/share/nginx/html")
        expect(content).to include("EXPOSE 8080") # unprivileged nginx can't bind 80
        expect(content).to include("daemon off")
      end
    end

    context "go" do
      it "generates a multi-stage Go Dockerfile" do
        content = generate(framework: "go", port: 8080, metadata: { "go_version" => "1.22", "module_name" => "github.com/user/app" })
        expect(content).to include("golang:1.22-alpine AS build")
        expect(content).to include("CGO_ENABLED=0")
        expect(content).to include("distroless")
        expect(content).to include("EXPOSE 8080")
      end
    end

    context "bun" do
      it "generates a Bun Dockerfile" do
        content = generate(framework: "bun", port: 3000, metadata: { "start_script" => "start" })
        expect(content).to include("oven/bun:1-alpine")
        expect(content).to include("bun install --frozen-lockfile")
        expect(content).to include("EXPOSE 3000")
      end

      it "uses bun run build when build_script is present" do
        content = generate(framework: "bun", port: 3000, metadata: { "build_script" => "build" })
        expect(content).to include("bun run build")
      end
    end

    context "elixir (plain)" do
      it "generates an Elixir Dockerfile" do
        content = generate(framework: "elixir", port: 4000, metadata: { "mix_project" => "my_app", "has_phoenix" => false })
        expect(content).to include("hexpm/elixir")
        expect(content).to include("mix release")
        expect(content).to include("my_app")
      end
    end

    context "elixir (phoenix)" do
      it "generates a multi-stage Phoenix Dockerfile" do
        content = generate(framework: "elixir", port: 4000, metadata: { "mix_project" => "my_app", "has_phoenix" => true })
        expect(content).to include("AS build")
        expect(content).to include("mix assets.deploy")
        expect(content).to include("PHX_SERVER=true")
        expect(content).to include("bin/my_app")
      end
    end

    context "unknown framework (docker)" do
      it "returns the existing path without generating" do
        File.write(File.join(repo_path, "Dockerfile"), "FROM scratch\n")
        det = detection(framework: "docker", port: 8080)
        result = described_class.new(repo_path, det).call
        expect(result).to eq(File.join(repo_path, "Dockerfile"))
      end
    end

    context "lockfile-based installs" do
      it "uses pnpm with corepack in every stage that runs it" do
        content = generate(framework: "node", port: 3000,
                           metadata: { "package_manager" => "pnpm", "lockfile" => "pnpm-lock.yaml", "build_script" => "tsc", "start_script" => "node dist/index.js" })
        expect(content).to include("COPY package.json pnpm-lock.yaml ./")
        expect(content).to include("RUN corepack enable && pnpm install --frozen-lockfile")
        expect(content).to include("RUN corepack enable && pnpm run build")
        expect(content).to include("RUN corepack enable && pnpm prune --prod")
      end

      it "uses yarn --immutable for yarn berry" do
        content = generate(framework: "nextjs", port: 3000,
                           metadata: { "package_manager" => "yarn", "lockfile" => "yarn.lock", "yarn_berry" => true })
        expect(content).to include("COPY package.json yarn.lock .yarnrc.yml* ./")
        expect(content).to include("corepack enable && yarn install --immutable")
      end

      it "does not rely on a workspace-root lockfile outside the build context" do
        content = generate(framework: "node", port: 3000,
                           metadata: { "package_manager" => "npm", "lockfile" => "package-lock.json", "workspace_lockfile" => true, "start_script" => "x" })
        expect(content).to include("COPY package.json ./")
        expect(content).to include("npm install --omit=dev")
      end

      it "skips BUNDLE_DEPLOYMENT without a Gemfile.lock" do
        content = generate(framework: "rails", port: 3000, metadata: { "bundler_lock" => false })
        expect(content).not_to include("BUNDLE_DEPLOYMENT")
      end

      it "installs uv from the lockfile for uv projects" do
        content = generate(framework: "fastapi", port: 8000, metadata: { "package_manager" => "uv", "has_uvicorn" => true })
        expect(content).to include("COPY pyproject.toml uv.lock ./")
        expect(content).to include("uv sync --frozen --no-dev")
        expect(content).not_to match(/pip install --no-cache-dir uvicorn/)
      end

      it "adds the ASGI server when the app didn't declare one" do
        content = generate(framework: "fastapi", port: 8000, metadata: { "has_uvicorn" => false })
        expect(content).to include("RUN pip install --no-cache-dir uvicorn")
      end
    end

    context "rails production defaults" do
      it "precompiles assets with a dummy secret and runs as a non-root user" do
        content = generate(framework: "rails", port: 3000,
                           metadata: { "ruby_version" => "3.3.6", "bundler_lock" => true, "assets" => true, "rails_version" => "8.0.2", "database_adapter" => "postgresql" })
        expect(content).to include("SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile")
        expect(content).to include("libpq-dev")
        expect(content).to include("libpq5")
        expect(content).to include("FROM ruby:3.3.6-slim AS base")
      end

      it "skips asset precompilation for API-only apps and /up for old Rails" do
        content = generate(framework: "rails", port: 3000, metadata: { "assets" => false, "rails_version" => "6.1.7" })
        expect(content).not_to include("assets:precompile")
        expect(content).not_to include("HEALTHCHECK")
      end

      it "binds rails server to $PORT without a puma config" do
        content = generate(framework: "rails", port: 3000, metadata: { "has_puma_config" => false })
        expect(content).to include("rails server -b 0.0.0.0 -p ${PORT}")
      end
    end

    context "nextjs variants" do
      it "falls back to next start when output isn't standalone" do
        content = generate(framework: "nextjs", port: 3000, metadata: { "next_standalone" => false })
        expect(content).to include(%(CMD ["node_modules/.bin/next", "start", "-H", "0.0.0.0"]))
        expect(content).not_to include(".next/standalone")
      end

      it "serves output: export builds from nginx" do
        content = generate(framework: "nextjs", port: 3000, metadata: { "next_export" => true })
        expect(content).to include("COPY --from=build /app/out /usr/share/nginx/html")
        expect(content).to include("nginx-unprivileged")
      end

      it "omits the public dir copy when the app has none" do
        content = generate(framework: "nextjs", port: 3000, metadata: { "next_standalone" => true, "has_public_dir" => false })
        expect(content).not_to include("/app/public")
      end
    end

    context "python start commands" do
      it "uses the Procfile web command when present" do
        content = generate(framework: "django", port: 8000, metadata: { "procfile_web" => "gunicorn mysite.wsgi --log-file -" })
        expect(content).to include(%(CMD ["sh", "-c", "exec gunicorn mysite.wsgi --log-file -"]))
      end

      it "binds gunicorn to $PORT" do
        content = generate(framework: "flask", port: 5000, metadata: { "wsgi_app" => "app:create_app()" })
        expect(content).to include("gunicorn --bind 0.0.0.0:${PORT}")
        expect(content).to include("app:create_app()")
      end
    end

    context "monorepos" do
      it "writes the Dockerfile and .dockerignore into the app directory" do
        FileUtils.mkdir_p(File.join(repo_path, "apps/api"))
        det = FrameworkDetector::Result.new(framework: "go", runtime: "go1.25", port: 8080, metadata: {}, root_dir: "apps/api")

        path = described_class.new(repo_path, det).call
        expect(path).to eq(File.join(repo_path, "apps/api/Dockerfile"))
        expect(File).to exist(File.join(repo_path, "apps/api/.dockerignore"))
        expect(File).not_to exist(File.join(repo_path, "Dockerfile"))
      end
    end

    context ".dockerignore" do
      it "excludes secrets and dependency dirs but keeps templates" do
        generate(framework: "rails", port: 3000)
        ignore = File.read(File.join(repo_path, ".dockerignore"))
        expect(ignore).to include(".env\n", "!.env.example", "/config/master.key", "/vendor/bundle")
        expect(ignore).not_to match(/^\*\.md$/)
      end

      it "does not overwrite an existing .dockerignore" do
        File.write(File.join(repo_path, ".dockerignore"), "custom\n")
        generate(framework: "go", port: 8080)
        expect(File.read(File.join(repo_path, ".dockerignore"))).to eq("custom\n")
      end
    end

    context "determinism" do
      it "produces identical output for identical detections" do
        det = detection(framework: "nextjs", port: 3000, metadata: { "node_version" => "22", "package_manager" => "pnpm", "lockfile" => "pnpm-lock.yaml" })
        a = described_class.new(nil, det).dockerfile
        b = described_class.new(nil, det).dockerfile
        expect(a).to eq(b)
      end
    end
  end

  describe ".preview" do
    it "renders without touching the filesystem and accepts symbol keys" do
      content = described_class.preview("go", go_version: "1.24", main_package: "./cmd/api")
      expect(content).to include("FROM golang:1.24-alpine AS build")
      expect(content).to include("-o /out/app ./cmd/api")
    end

    it "returns nil for docker repos" do
      expect(described_class.preview("docker", {})).to be_nil
    end
  end
end
