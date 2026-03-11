require "rails_helper"

RSpec.describe FrameworkDetector do
  let(:project) { create(:project) }
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  subject { described_class.new(repo_path, project) }

  def touch(filename)
    FileUtils.touch(File.join(repo_path, filename))
  end

  def write(filename, content)
    File.write(File.join(repo_path, filename), content)
  end

  describe "#call" do
    # ── Original frameworks ──────────────────────────────────────── #

    it "detects docker when Dockerfile exists" do
      touch("Dockerfile")
      expect(subject.call.framework).to eq("docker")
    end

    it "detects rails when Gemfile contains rails" do
      write("Gemfile", 'gem "rails", "~> 8.0"')
      result = subject.call
      expect(result.framework).to eq("rails")
      expect(result.port).to eq(3000)
    end

    it "reads ruby_version from .ruby-version for rails" do
      write("Gemfile", 'gem "rails"')
      write(".ruby-version", "3.3.0")
      result = subject.call
      expect(result.metadata["ruby_version"]).to eq("3.3.0")
    end

    it "detects node when package.json exists (no next dependency)" do
      write("package.json", '{"dependencies": {"express": "^4.0"}}')
      expect(subject.call.framework).to eq("node")
    end

    it "reads node_version from .nvmrc for node" do
      write("package.json", "{}")
      write(".nvmrc", "18")
      result = subject.call
      expect(result.metadata["node_version"]).to eq("18")
    end

    it "detects python when requirements.txt exists (no specific framework)" do
      write("requirements.txt", "httpx\nrequests")
      expect(subject.call.framework).to eq("python")
    end

    it "detects static when only index.html is present" do
      touch("index.html")
      expect(subject.call.framework).to eq("static")
    end

    it "falls back to static when nothing is detected" do
      expect(subject.call.framework).to eq("static")
    end

    # ── Specificity: docker wins over everything ─────────────────── #

    it "prefers docker over rails when both exist" do
      touch("Dockerfile")
      write("Gemfile", 'gem "rails"')
      expect(subject.call.framework).to eq("docker")
    end

    it "prefers docker over python when both exist" do
      touch("Dockerfile")
      write("requirements.txt", "fastapi")
      expect(subject.call.framework).to eq("docker")
    end

    # ── New: FastAPI ─────────────────────────────────────────────── #

    it "detects fastapi when requirements.txt starts with fastapi" do
      write("requirements.txt", "fastapi==0.100\nuvicorn")
      result = subject.call
      expect(result.framework).to eq("fastapi")
      expect(result.port).to eq(8000)
      expect(result.runtime).to eq("python3.11")
    end

    it "detects fastapi from pyproject.toml when requirements.txt absent" do
      write("pyproject.toml", "[tool.poetry.dependencies]\nfastapi = \"*\"")
      result = subject.call
      expect(result.framework).to eq("fastapi")
    end

    it "prefers fastapi over generic python" do
      write("requirements.txt", "fastapi\nhttpx")
      expect(subject.call.framework).to eq("fastapi")
    end

    it "detects fastapi entry point from main.py" do
      write("requirements.txt", "fastapi")
      write("main.py", "from fastapi import FastAPI\napp = FastAPI()")
      result = subject.call
      expect(result.metadata["entry_point"]).to eq("main.py")
    end

    # ── New: Flask ───────────────────────────────────────────────── #

    it "detects flask when requirements.txt starts with flask" do
      write("requirements.txt", "flask==3.0\ngunicorn")
      result = subject.call
      expect(result.framework).to eq("flask")
      expect(result.port).to eq(5000)
    end

    it "prefers flask over generic python" do
      write("requirements.txt", "flask\nrequests")
      expect(subject.call.framework).to eq("flask")
    end

    # fastapi is checked before flask in DETECTORS
    it "prefers fastapi over flask when both present" do
      write("requirements.txt", "fastapi\nflask")
      expect(subject.call.framework).to eq("fastapi")
    end

    # ── New: Django ──────────────────────────────────────────────── #

    it "detects django via manage.py" do
      touch("manage.py")
      result = subject.call
      expect(result.framework).to eq("django")
      expect(result.port).to eq(8000)
    end

    it "detects django via requirements.txt starting with django" do
      write("requirements.txt", "django==4.2\ngunicorn")
      result = subject.call
      expect(result.framework).to eq("django")
    end

    it "extracts wsgi module from manage.py when available" do
      write("manage.py", "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'myapp.settings')")
      result = subject.call
      expect(result.metadata["wsgi_module"]).to eq("myapp.wsgi")
    end

    # ── New: Next.js ─────────────────────────────────────────────── #

    it "detects nextjs when package.json has next in dependencies" do
      write("package.json", JSON.generate("dependencies" => { "next" => "^14.0", "react" => "^18.0" }))
      result = subject.call
      expect(result.framework).to eq("nextjs")
      expect(result.port).to eq(3000)
    end

    it "prefers nextjs over generic node" do
      write("package.json", JSON.generate("dependencies" => { "next" => "^14", "express" => "^4" }))
      expect(subject.call.framework).to eq("nextjs")
    end

    it "detects node (not nextjs) when next is not a dependency" do
      write("package.json", JSON.generate("dependencies" => { "express" => "^4.0" }))
      expect(subject.call.framework).to eq("node")
    end

    # ── New: Go ──────────────────────────────────────────────────── #

    it "detects go when go.mod exists" do
      write("go.mod", "module github.com/user/myapp\n\ngo 1.21\n")
      result = subject.call
      expect(result.framework).to eq("go")
      expect(result.port).to eq(8080)
      expect(result.runtime).to eq("go1.22")
    end

    it "reads go version from go.mod" do
      write("go.mod", "module example.com/app\n\ngo 1.22.3\n")
      result = subject.call
      expect(result.metadata["go_version"]).to eq("1.22")
    end

    it "reads module name from go.mod" do
      write("go.mod", "module github.com/myorg/myservice\n\ngo 1.21\n")
      result = subject.call
      expect(result.metadata["module_name"]).to eq("github.com/myorg/myservice")
    end

    it "prefers docker over go" do
      touch("Dockerfile")
      write("go.mod", "module example.com/app\n\ngo 1.21\n")
      expect(subject.call.framework).to eq("docker")
    end

    # ── New: Bun ─────────────────────────────────────────────────── #

    it "detects bun when bun.lockb exists" do
      write("package.json", '{"scripts":{"start":"bun run index.ts"}}')
      touch("bun.lockb")
      result = subject.call
      expect(result.framework).to eq("bun")
      expect(result.port).to eq(3000)
    end

    it "detects bun when bun.lock exists" do
      write("package.json", "{}")
      touch("bun.lock")
      result = subject.call
      expect(result.framework).to eq("bun")
    end

    it "prefers bun over node when both package.json and bun.lockb exist" do
      write("package.json", '{"dependencies":{"express":"^4"}}')
      touch("bun.lockb")
      expect(subject.call.framework).to eq("bun")
    end

    # ── New: Elixir ───────────────────────────────────────────────── #

    it "detects elixir when mix.exs exists" do
      write("mix.exs", "defmodule MyApp.MixProject do\n  def project, do: [app: :my_app]\nend\n")
      result = subject.call
      expect(result.framework).to eq("elixir")
      expect(result.port).to eq(4000)
    end

    it "detects phoenix apps" do
      write("mix.exs", "defmodule MyApp.MixProject do\n  def project, do: [app: :my_app]\n  {:phoenix, \"~> 1.7\"}\nend\n")
      result = subject.call
      expect(result.framework).to eq("elixir")
      expect(result.metadata["has_phoenix"]).to be true
    end

    it "reads app name from mix.exs" do
      write("mix.exs", "defmodule MyApp.MixProject do\n  def project do\n    [app: :hello_world]\n  end\nend\n")
      result = subject.call
      expect(result.metadata["mix_project"]).to eq("hello_world")
    end

    # ── Static only matches without server-side signals ──────────── #

    it "does not detect static when package.json is present" do
      touch("index.html")
      write("package.json", "{}")
      expect(subject.call.framework).not_to eq("static")
    end

    it "does not detect static when requirements.txt is present" do
      touch("index.html")
      write("requirements.txt", "flask")
      expect(subject.call.framework).not_to eq("static")
    end

    it "does not detect static when go.mod is present" do
      touch("index.html")
      write("go.mod", "module example.com\n\ngo 1.21\n")
      expect(subject.call.framework).not_to eq("static")
    end

    # ── Persistence ──────────────────────────────────────────────── #

    it "persists framework, runtime, and port onto the project" do
      write("requirements.txt", "fastapi\nuvicorn")
      subject.call
      project.reload
      expect(project.framework).to eq("fastapi")
      expect(project.runtime).to eq("python3.11")
      expect(project.port).to eq(8000)
    end

    # ── Return value ─────────────────────────────────────────────── #

    it "returns a Result struct with framework, runtime, port, metadata" do
      touch("index.html")
      result = subject.call
      expect(result).to be_a(FrameworkDetector::Result)
      expect(result).to respond_to(:framework, :runtime, :port, :metadata)
    end
  end
end
