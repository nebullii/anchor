require "rails_helper"

RSpec.describe Analysis::DependencyReader do
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  def write(filename, content)
    File.write(File.join(repo_path, filename), content)
  end

  subject(:reader) { described_class.new(repo_path, framework) }

  describe "#call" do
    context "with a Rails app" do
      let(:framework) { "rails" }

      it "returns gem names from Gemfile" do
        write("Gemfile", <<~GEMFILE)
          source "https://rubygems.org"
          gem "rails", "~> 8.0"
          gem "pg", "~> 1.1"
          gem "sidekiq"
        GEMFILE
        expect(reader.call).to contain_exactly("rails", "pg", "sidekiq")
      end

      it "ignores comment lines" do
        write("Gemfile", <<~GEMFILE)
          # This is a comment
          gem "rails"
          # gem "not_included"
        GEMFILE
        expect(reader.call).to eq(["rails"])
      end

      it "returns empty array when Gemfile does not exist" do
        expect(reader.call).to eq([])
      end
    end

    context "with a Python app" do
      let(:framework) { "python" }

      it "returns package names from requirements.txt" do
        write("requirements.txt", <<~REQS)
          fastapi==0.100.0
          uvicorn>=0.20.0
          sqlalchemy
          httpx
        REQS
        expect(reader.call).to contain_exactly("fastapi", "uvicorn", "sqlalchemy", "httpx")
      end

      it "strips version specifiers" do
        write("requirements.txt", "django>=4.0,<5.0\ngunicorn==20.1.0")
        deps = reader.call
        expect(deps).to include("django")
        expect(deps).to include("gunicorn")
        expect(deps).not_to include(">=4.0,<5.0")
      end

      it "ignores blank lines and comments" do
        write("requirements.txt", <<~REQS)
          # production dependencies
          fastapi

          uvicorn
        REQS
        expect(reader.call).to contain_exactly("fastapi", "uvicorn")
      end

      it "returns empty array when requirements.txt does not exist" do
        expect(reader.call).to eq([])
      end
    end

    context "with a FastAPI app" do
      let(:framework) { "fastapi" }

      it "reads requirements.txt the same as python" do
        write("requirements.txt", "fastapi\nuvicorn\npsycopg2-binary")
        expect(reader.call).to include("fastapi", "uvicorn", "psycopg2-binary")
      end
    end

    context "with a Node.js app" do
      let(:framework) { "node" }

      it "returns dependency names from package.json" do
        write("package.json", JSON.generate(
          "dependencies" => {
            "express" => "^4.18",
            "pg"      => "^8.0",
            "dotenv"  => "^16.0"
          }
        ))
        expect(reader.call).to contain_exactly("express", "pg", "dotenv")
      end

      it "does not include devDependencies" do
        write("package.json", JSON.generate(
          "dependencies"    => { "express" => "^4.0" },
          "devDependencies" => { "jest" => "^29.0" }
        ))
        expect(reader.call).to eq(["express"])
      end

      it "returns empty array when package.json does not exist" do
        expect(reader.call).to eq([])
      end

      it "returns empty array when dependencies key is absent" do
        write("package.json", JSON.generate("name" => "my-app"))
        expect(reader.call).to eq([])
      end
    end

    context "with a Next.js app" do
      let(:framework) { "nextjs" }

      it "reads from package.json like node" do
        write("package.json", JSON.generate(
          "dependencies" => { "next" => "^14.0", "react" => "^18.0" }
        ))
        expect(reader.call).to include("next", "react")
      end
    end

    context "with an unsupported framework" do
      let(:framework) { "static" }

      it "returns an empty array" do
        expect(reader.call).to eq([])
      end
    end
  end
end
