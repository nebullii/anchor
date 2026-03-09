require "rails_helper"

RSpec.describe RepositoryAnalyzer do
  let(:project)   { create(:project) }
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  def write(filename, content)
    path = File.join(repo_path, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def touch(filename)
    FileUtils.touch(File.join(repo_path, filename))
  end

  subject(:analyzer) { described_class.new(repo_path, project) }

  describe "#call" do
    it "returns a Result struct" do
      touch("index.html")
      result = analyzer.call
      expect(result).to be_a(RepositoryAnalyzer::Result)
    end

    it "includes all required fields" do
      touch("index.html")
      result = analyzer.call
      expect(result).to respond_to(
        :framework, :runtime, :port, :detected_env_vars,
        :detected_database, :dependencies, :has_dockerfile,
        :warnings, :confidence
      )
    end

    context "with a Rails app" do
      before do
        write("Gemfile", "gem \"rails\"\ngem \"pg\"")
        write("app/models/user.rb", 'ENV["SECRET_KEY_BASE"]')
      end

      it "sets framework to rails" do
        expect(analyzer.call.framework).to eq("rails")
      end

      it "detects PostgreSQL database" do
        result = analyzer.call
        expect(result.detected_database["adapter"]).to eq("postgresql")
      end

      it "auto-adds DATABASE_URL to env vars when database detected" do
        result = analyzer.call
        keys = result.detected_env_vars.map { |v| v["key"] }
        expect(keys).to include("DATABASE_URL")
      end

      it "does not duplicate DATABASE_URL if already in source scan" do
        write("config/database.yml", 'ENV["DATABASE_URL"]')
        result = analyzer.call
        expect(result.detected_env_vars.count { |v| v["key"] == "DATABASE_URL" }).to eq(1)
      end

      it "marks has_dockerfile false when no Dockerfile present" do
        expect(analyzer.call.has_dockerfile).to be false
      end

      it "marks has_dockerfile true when Dockerfile present" do
        touch("Dockerfile")
        expect(analyzer.call.has_dockerfile).to be true
      end

      it "includes a warning about missing Dockerfile" do
        result = analyzer.call
        expect(result.warnings).to include(a_string_matching(/Dockerfile/))
      end

      it "returns confidence high for rails" do
        expect(analyzer.call.confidence).to eq("high")
      end
    end

    context "with a FastAPI app" do
      before do
        write("requirements.txt", "fastapi\npsycopg2-binary\n")
        write("main.py", "from fastapi import FastAPI\napp = FastAPI()\nkey = os.getenv('OPENAI_API_KEY')")
      end

      it "sets framework to fastapi" do
        expect(analyzer.call.framework).to eq("fastapi")
      end

      it "detects PostgreSQL via psycopg2" do
        result = analyzer.call
        expect(result.detected_database["adapter"]).to eq("postgresql")
      end

      it "detects OPENAI_API_KEY from source" do
        result = analyzer.call
        keys = result.detected_env_vars.map { |v| v["key"] }
        expect(keys).to include("OPENAI_API_KEY")
      end

      it "warns about missing uvicorn" do
        result = analyzer.call
        expect(result.warnings).to include(a_string_matching(/uvicorn/))
      end

      it "does not warn about uvicorn when it is present" do
        write("requirements.txt", "fastapi\nuvicorn\npsycopg2-binary")
        result = analyzer.call
        expect(result.warnings).not_to include(a_string_matching(/uvicorn/))
      end
    end

    context "with a Flask app" do
      before do
        write("requirements.txt", "flask\n")
        write("app.py", "from flask import Flask\napp = Flask(__name__)")
      end

      it "sets framework to flask" do
        expect(analyzer.call.framework).to eq("flask")
      end

      it "warns about missing gunicorn" do
        result = analyzer.call
        expect(result.warnings).to include(a_string_matching(/gunicorn/))
      end
    end

    context "with a Django app" do
      before do
        write("requirements.txt", "django==4.2\n")
        write("manage.py", "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'myapp.settings')")
      end

      it "sets framework to django" do
        expect(analyzer.call.framework).to eq("django")
      end

      it "warns about missing gunicorn" do
        result = analyzer.call
        expect(result.warnings).to include(a_string_matching(/gunicorn/))
      end

      it "does not warn when gunicorn is present" do
        write("requirements.txt", "django\ngunicorn")
        result = analyzer.call
        expect(result.warnings).not_to include(a_string_matching(/gunicorn/))
      end
    end

    context "with a static site" do
      before { touch("index.html") }

      it "sets framework to static" do
        expect(analyzer.call.framework).to eq("static")
      end

      it "returns confidence low" do
        expect(analyzer.call.confidence).to eq("low")
      end

      it "includes a warning about static detection" do
        result = analyzer.call
        expect(result.warnings).to include(a_string_matching(/static site/))
      end
    end

    context "with a custom Docker repo" do
      before { touch("Dockerfile") }

      it "sets framework to docker" do
        expect(analyzer.call.framework).to eq("docker")
      end

      it "returns confidence high" do
        expect(analyzer.call.confidence).to eq("high")
      end

      it "marks has_dockerfile true" do
        expect(analyzer.call.has_dockerfile).to be true
      end

      it "does not warn about missing Dockerfile" do
        result = analyzer.call
        expect(result.warnings).not_to include(a_string_matching(/Dockerfile/))
      end
    end

    describe "#to_h" do
      it "returns a plain hash suitable for JSON storage" do
        touch("index.html")
        result = analyzer.call.to_h
        expect(result).to be_a(Hash)
        expect(result.keys).to include(
          :framework, :runtime, :port, :detected_env_vars,
          :detected_database, :dependencies, :has_dockerfile,
          :warnings, :confidence
        )
      end
    end
  end
end
