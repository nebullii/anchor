require "rails_helper"

RSpec.describe Deployments::PlanBuilder do
  let(:user) { create(:user) }
  let(:project) { create(:project, user: user) }

  describe "#call" do
    it "builds a deployment plan with readiness and env var grouping" do
      analysis = {
        "framework" => "fastapi",
        "runtime" => "python3.11",
        "port" => 8000,
        "has_dockerfile" => false,
        "warnings" => ["No health endpoint detected"],
        "detected_env_vars" => [
          { "key" => "DATABASE_URL", "required" => true },
          { "key" => "REDIS_URL", "required" => false }
        ],
        "ai_env_var_suggestions" => [
          { "key" => "STRIPE_SECRET_KEY", "required" => true, "confidence" => "high" },
          { "key" => "SENTRY_DSN", "required" => false, "confidence" => "possible" }
        ]
      }

      create(:secret, project: project, key: "DATABASE_URL", value: "postgres://example")

      plan = described_class.new(project: project, analysis_result: analysis, user: user).call

      expect(plan["framework"]).to eq("fastapi")
      expect(plan["runtime"]).to eq("python3.11")
      expect(plan["container"]).to eq("Generated Dockerfile")
      expect(plan["target"]).to eq("Google Cloud Run")
      expect(plan["required_env_vars"]).to include("DATABASE_URL", "STRIPE_SECRET_KEY")
      expect(plan["optional_env_vars"]).to include("REDIS_URL", "SENTRY_DSN")
      expect(plan["missing_required_env_vars"]).to include("STRIPE_SECRET_KEY")
      expect(plan["deployment_readiness"]).to be_between(0, 100)
    end
  end
end
