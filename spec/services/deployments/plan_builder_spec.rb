require "rails_helper"

RSpec.describe Deployments::PlanBuilder do
  let(:user) { create(:user) }
  let(:project) { create(:project, user: user) }

  let(:analysis) do
    {
      "framework" => "fastapi",
      "runtime" => "python3.11",
      "port" => 8000,
      "has_dockerfile" => false,
      "warnings" => ["No health endpoint detected"],
      "detected_env_vars" => [
        { "key" => "DATABASE_URL", "required" => true, "source" => "database", "hint" => "Connection string" },
        { "key" => "REDIS_URL", "required" => false, "source" => "redis", "hint" => "Redis connection" }
      ],
      "detected_database" => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "dependencies" => ["fastapi", "uvicorn", "psycopg2-binary", "redis"],
      "ai_env_var_suggestions" => [
        { "key" => "STRIPE_SECRET_KEY", "required" => true, "confidence" => "high", "reason" => "Stripe SDK detected" },
        { "key" => "SENTRY_DSN", "required" => false, "confidence" => "possible", "reason" => "Sentry SDK found" }
      ]
    }
  end

  subject(:plan) { described_class.new(project: project, analysis_result: analysis, user: user).call }

  describe "#call" do
    before do
      create(:secret, project: project, key: "DATABASE_URL", value: "postgres://example")
    end

    # ── Legacy keys (backward compatibility) ──────────────────────

    it "preserves all legacy keys used by existing views" do
      expect(plan["framework"]).to eq("fastapi")
      expect(plan["runtime"]).to eq("python3.11")
      expect(plan["port"]).to eq(8000)
      expect(plan["container"]).to eq("Generated Dockerfile")
      expect(plan["target"]).to eq("Google Cloud Run")
      expect(plan["required_env_vars"]).to include("DATABASE_URL", "STRIPE_SECRET_KEY")
      expect(plan["optional_env_vars"]).to include("REDIS_URL", "SENTRY_DSN")
      expect(plan["missing_required_env_vars"]).to include("STRIPE_SECRET_KEY")
      expect(plan["missing_required_env_vars"]).not_to include("DATABASE_URL")
      expect(plan["deployment_readiness"]).to be_between(0, 100)
      expect(plan["risks"]).to include("No health endpoint detected")
    end

    # ── project_type ──────────────────────────────────────────────

    it "infers project_type from framework" do
      expect(plan["project_type"]).to eq("api_service")
    end

    # ── detected_stack ────────────────────────────────────────────

    it "builds detected_stack with framework, database, and package managers" do
      stack = plan["detected_stack"]
      expect(stack["framework"]).to eq("fastapi")
      expect(stack["database"]).to eq("postgresql")
      expect(stack["package_managers"]).to eq(["pip"])
      expect(stack["cache"]).to eq("redis")
    end

    # ── deployment_strategy ───────────────────────────────────────

    it "builds deployment_strategy with build steps and entrypoint" do
      strategy = plan["deployment_strategy"]
      expect(strategy["containerized"]).to be true
      expect(strategy["port"]).to eq(8000)
      expect(strategy["runtime"]).to eq("python3.11")
      expect(strategy["entrypoint"]).to include("uvicorn")
      expect(strategy["build_steps"]).to be_an(Array)
      expect(strategy["build_steps"]).to include("pip install -r requirements.txt")
    end

    it "uses user Dockerfile build step when Dockerfile exists" do
      analysis["has_dockerfile"] = true
      strategy = plan["deployment_strategy"]
      expect(strategy["build_steps"]).to eq(["docker build (user-provided Dockerfile)"])
    end

    # ── env_vars (structured) ─────────────────────────────────────

    it "builds structured env_vars with required and optional sections" do
      env = plan["env_vars"]
      expect(env["required"]).to be_an(Array)
      expect(env["optional"]).to be_an(Array)

      db_var = env["required"].find { |v| v["name"] == "DATABASE_URL" }
      expect(db_var).to be_present
      expect(db_var["configured"]).to be true
      expect(db_var["reason"]).to eq("Connection string")

      stripe_var = env["required"].find { |v| v["name"] == "STRIPE_SECRET_KEY" }
      expect(stripe_var).to be_present
      expect(stripe_var["configured"]).to be false

      redis_var = env["optional"].find { |v| v["name"] == "REDIS_URL" }
      expect(redis_var).to be_present
      expect(redis_var["configured"]).to be false
    end

    # ── dependencies ──────────────────────────────────────────────

    it "detects external dependencies from analysis" do
      deps = plan["dependencies"]
      expect(deps).to be_an(Array)

      db_dep = deps.find { |d| d["type"] == "database" }
      expect(db_dep["service"]).to eq("postgresql")
      expect(db_dep["required"]).to be true

      redis_dep = deps.find { |d| d["type"] == "cache" }
      expect(redis_dep["service"]).to eq("redis")
    end

    it "returns empty dependencies when nothing detected" do
      analysis.delete("detected_database")
      analysis["dependencies"] = ["fastapi", "uvicorn"]
      result = described_class.new(project: project, analysis_result: analysis, user: user).call
      expect(result["dependencies"]).to eq([])
    end

    # ── provider_plan ─────────────────────────────────────────────

    it "builds provider_plan for Google Cloud" do
      provider = plan["provider_plan"]
      expect(provider["provider"]).to eq("google_cloud")
      expect(provider["services"]).to include("Cloud Run (compute)")
      expect(provider["region"]).to eq(project.gcp_region)
      expect(provider["notes"]).to be_an(Array)
      expect(provider["notes"]).to include(a_string_matching(/database/i))
    end

    # ── files_to_generate ─────────────────────────────────────────

    it "lists files to generate when no Dockerfile exists" do
      files = plan["files_to_generate"]
      expect(files).to be_an(Array)

      dockerfile = files.find { |f| f["path"] == "Dockerfile" }
      expect(dockerfile).to be_present
      expect(dockerfile["action"]).to eq("create")

      dockerignore = files.find { |f| f["path"] == ".dockerignore" }
      expect(dockerignore).to be_present
    end

    it "skips Dockerfile in files_to_generate when one exists" do
      analysis["has_dockerfile"] = true
      files = plan["files_to_generate"]
      expect(files.map { |f| f["path"] }).not_to include("Dockerfile")
    end

    # ── Framework-specific project types ──────────────────────────

    {
      "rails"   => "web_application",
      "nextjs"  => "fullstack_web",
      "django"  => "web_application",
      "flask"   => "web_application",
      "node"    => "web_application",
      "go"      => "api_service",
      "static"  => "static_site",
      "docker"  => "containerized",
      "unknown" => "unknown"
    }.each do |fw, expected_type|
      it "maps #{fw} framework to #{expected_type} project type" do
        analysis["framework"] = fw
        result = described_class.new(project: project, analysis_result: analysis, user: user).call
        expect(result["project_type"]).to eq(expected_type)
      end
    end
  end
end
