require "rails_helper"

RSpec.describe Analysis::EnvVarDetector do
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  def write(filename, content)
    path = File.join(repo_path, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  subject(:detector) { described_class.new(repo_path, framework) }

  describe "#call" do
    context "with a Ruby/Rails app" do
      let(:framework) { "rails" }

      it "detects ENV[] access" do
        write("config/initializers/stripe.rb", 'key = ENV["STRIPE_SECRET_KEY"]')
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("STRIPE_SECRET_KEY")
      end

      it "detects ENV.fetch access" do
        write("config/initializers/database.rb", "ENV.fetch('DATABASE_URL')")
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("DATABASE_URL")
      end

      it "marks known required vars as required" do
        write("app/models/user.rb", 'ENV["STRIPE_SECRET_KEY"]')
        result = detector.call.find { |v| v["key"] == "STRIPE_SECRET_KEY" }
        expect(result["required"]).to be true
      end

      it "marks unknown vars as not required" do
        write("app/services/foo.rb", 'ENV["MY_CUSTOM_FLAG"]')
        result = detector.call.find { |v| v["key"] == "MY_CUSTOM_FLAG" }
        expect(result["required"]).to be false
      end

      it "annotates known vars with their source" do
        write("lib/openai.rb", 'ENV["OPENAI_API_KEY"]')
        result = detector.call.find { |v| v["key"] == "OPENAI_API_KEY" }
        expect(result["source"]).to eq("openai")
      end

      it "filters out reserved system keys" do
        write("config/puma.rb", 'ENV["PORT"]')
        keys = detector.call.map { |v| v["key"] }
        expect(keys).not_to include("PORT")
        expect(keys).not_to include("HOST")
        expect(keys).not_to include("RACK_ENV")
      end

      it "filters out keys shorter than 4 characters" do
        write("app/jobs/foo.rb", 'ENV["AB"]')
        keys = detector.call.map { |v| v["key"] }
        expect(keys).not_to include("AB")
      end

      it "deduplicates keys found in multiple files" do
        write("app/models/user.rb",    'ENV["DATABASE_URL"]')
        write("config/database.yml",   'ENV["DATABASE_URL"]')
        keys = detector.call.map { |v| v["key"] }
        expect(keys.count("DATABASE_URL")).to eq(1)
      end

      it "returns required vars sorted before optional ones" do
        write("app.rb", 'ENV["STRIPE_SECRET_KEY"]; ENV["SENTRY_DSN"]')
        result = detector.call
        required_indices  = result.each_index.select { |i| result[i]["required"] }
        optional_indices  = result.each_index.select { |i| !result[i]["required"] }
        expect(required_indices.max || -1).to be <= (optional_indices.min || 999)
      end

      it "skips node_modules and vendor directories" do
        write("node_modules/foo/index.rb", 'ENV["NODE_MODULES_SECRET"]')
        write("vendor/bundle/foo.rb",       'ENV["VENDOR_SECRET"]')
        keys = detector.call.map { |v| v["key"] }
        expect(keys).not_to include("NODE_MODULES_SECRET")
        expect(keys).not_to include("VENDOR_SECRET")
      end

      it "returns an empty array when no env vars are referenced" do
        write("app/models/user.rb", "class User < ApplicationRecord; end")
        expect(detector.call).to eq([])
      end
    end

    context "with a Python/FastAPI app" do
      let(:framework) { "fastapi" }

      it "detects os.environ[] access" do
        write("main.py", 'db_url = os.environ["DATABASE_URL"]')
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("DATABASE_URL")
      end

      it "detects os.getenv() access" do
        write("config.py", "openai_key = os.getenv('OPENAI_API_KEY')")
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("OPENAI_API_KEY")
      end

      it "detects os.environ.get() access" do
        write("app.py", "redis = os.environ.get('REDIS_URL')")
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("REDIS_URL")
      end
    end

    context "with a Node.js app" do
      let(:framework) { "node" }

      it "detects process.env.KEY access" do
        write("server.js", "const key = process.env.STRIPE_SECRET_KEY")
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("STRIPE_SECRET_KEY")
      end

      it "detects process.env['KEY'] access" do
        write("app.js", "const url = process.env['DATABASE_URL']")
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("DATABASE_URL")
      end

      it "scans TypeScript files" do
        write("src/config.ts", "const secret = process.env.MY_API_SECRET")
        keys = detector.call.map { |v| v["key"] }
        expect(keys).to include("MY_API_SECRET")
      end
    end
  end
end
