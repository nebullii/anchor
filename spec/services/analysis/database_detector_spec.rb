require "rails_helper"

RSpec.describe Analysis::DatabaseDetector do
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  def write(filename, content)
    File.write(File.join(repo_path, filename), content)
  end

  subject(:detector) { described_class.new(repo_path, framework) }

  describe "#call" do
    context "with a Rails app (Gemfile)" do
      let(:framework) { "rails" }

      it "detects PostgreSQL via pg gem" do
        write("Gemfile", "gem \"rails\"\ngem \"pg\", \"~> 1.1\"")
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
        expect(result["var"]).to eq("DATABASE_URL")
      end

      it "detects MySQL via mysql2 gem" do
        write("Gemfile", "gem \"rails\"\ngem \"mysql2\"")
        result = detector.call
        expect(result["adapter"]).to eq("mysql")
      end

      it "detects SQLite and returns nil var (no cloud DB needed)" do
        write("Gemfile", "gem \"rails\"\ngem \"sqlite3\"")
        result = detector.call
        expect(result["adapter"]).to eq("sqlite")
        expect(result["var"]).to be_nil
      end

      it "returns nil when no database gem is present" do
        write("Gemfile", "gem \"rails\"\ngem \"httparty\"")
        expect(detector.call).to be_nil
      end

      it "returns nil when Gemfile does not exist" do
        expect(detector.call).to be_nil
      end
    end

    context "with a Python app (requirements.txt)" do
      let(:framework) { "python" }

      it "detects PostgreSQL via psycopg2" do
        write("requirements.txt", "fastapi\npsycopg2-binary==2.9.5\nuvicorn")
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
        expect(result["var"]).to eq("DATABASE_URL")
      end

      it "detects PostgreSQL via asyncpg" do
        write("requirements.txt", "asyncpg\nhttpx")
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end

      it "detects PostgreSQL via SQLAlchemy (assumed pg pairing)" do
        write("requirements.txt", "SQLAlchemy==2.0.0\nfastapi")
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end

      it "detects MySQL via pymysql" do
        write("requirements.txt", "flask\npymysql")
        result = detector.call
        expect(result["adapter"]).to eq("mysql")
      end

      it "returns nil when no database package is present" do
        write("requirements.txt", "fastapi\nuvicorn\nhttpx")
        expect(detector.call).to be_nil
      end
    end

    context "with a FastAPI app" do
      let(:framework) { "fastapi" }

      it "detects database the same way as generic python" do
        write("requirements.txt", "fastapi\npsycopg2-binary\nuvicorn")
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end
    end

    context "with a Django app" do
      let(:framework) { "django" }

      it "infers PostgreSQL from the django package itself" do
        write("requirements.txt", "django==4.2\ngunicorn")
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end
    end

    context "with a Node.js app (package.json)" do
      let(:framework) { "node" }

      it "detects PostgreSQL via pg package" do
        write("package.json", JSON.generate("dependencies" => { "express" => "^4.0", "pg" => "^8.0" }))
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
        expect(result["var"]).to eq("DATABASE_URL")
      end

      it "detects MongoDB via mongoose" do
        write("package.json", JSON.generate("dependencies" => { "mongoose" => "^7.0" }))
        result = detector.call
        expect(result["adapter"]).to eq("mongodb")
        expect(result["var"]).to eq("MONGODB_URI")
      end

      it "detects PostgreSQL via prisma" do
        write("package.json", JSON.generate("dependencies" => { "@prisma/client" => "^5.0" }))
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end

      it "detects PostgreSQL via sequelize" do
        write("package.json", JSON.generate("dependencies" => { "sequelize" => "^6.0" }))
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end

      it "returns nil when no database package is present" do
        write("package.json", JSON.generate("dependencies" => { "express" => "^4.0" }))
        expect(detector.call).to be_nil
      end

      it "also checks devDependencies" do
        write("package.json", JSON.generate(
          "dependencies"    => { "express" => "^4.0" },
          "devDependencies" => { "pg" => "^8.0" }
        ))
        result = detector.call
        expect(result["adapter"]).to eq("postgresql")
      end

      it "returns nil when package.json does not exist" do
        expect(detector.call).to be_nil
      end
    end
  end
end
