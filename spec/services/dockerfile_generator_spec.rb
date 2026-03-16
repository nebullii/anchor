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

      it "defaults to ruby 3.2 when version is unknown" do
        content = generate(framework: "rails", port: 3000)
        expect(content).to include("ruby:3.2-slim")
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
        content = generate(framework: "nextjs", port: 3000, metadata: { "node_version" => "20", "has_lock_file" => true })
        expect(content).to include("AS deps")
        expect(content).to include("AS builder")
        expect(content).to include("AS runner")
        expect(content).to include("server.js")
      end
    end

    context "fastapi" do
      it "generates a FastAPI Dockerfile with uvicorn" do
        content = generate(framework: "fastapi", port: 8000, metadata: { "entry_point" => "main.py" })
        expect(content).to include("python:3.11-slim")
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
        expect(content).to include("nginx:alpine")
        expect(content).to include("/usr/share/nginx/html")
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
  end
end
