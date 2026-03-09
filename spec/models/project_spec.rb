require "rails_helper"

RSpec.describe Project, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:repository) }
    it { is_expected.to have_many(:deployments).dependent(:destroy) }
    it { is_expected.to have_many(:secrets).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:project) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:gcp_project_id) }
    it { is_expected.to validate_presence_of(:gcp_region) }
    it { is_expected.to validate_inclusion_of(:gcp_region).in_array(Project::REGIONS) }
    it { is_expected.to validate_inclusion_of(:analysis_status).in_array(Project::ANALYSIS_STATUSES) }
  end

  describe "constants" do
    it "includes new frameworks" do
      expect(Project::FRAMEWORKS).to include("fastapi", "flask", "django", "nextjs")
    end

    it "includes all analysis statuses" do
      expect(Project::ANALYSIS_STATUSES).to eq(%w[pending analyzing complete failed])
    end
  end

  describe "callbacks" do
    it "generates a slug from the name on create" do
      project = create(:project, name: "My App")
      expect(project.slug).to eq("my-app")
    end

    it "generates a unique slug with suffix when name is taken" do
      user = create(:user)
      repo = create(:repository, user: user)
      create(:project, user: user, repository: repo, name: "My App")
      project2 = create(:project, user: user, repository: repo, name: "My App 2")
      expect(project2.slug).to be_present
    end

    it "sets service_name from slug on create" do
      project = create(:project, name: "My App")
      expect(project.service_name).to eq("cl-#{project.slug}")
    end

    it "defaults analysis_status to pending" do
      project = create(:project)
      expect(project.analysis_status).to eq("pending")
    end
  end

  describe "#latest_deployment" do
    it "returns the most recent deployment" do
      project = create(:project)
      _old = create(:deployment, project: project, created_at: 1.hour.ago)
      new_d = create(:deployment, :success, project: project)
      expect(project.latest_deployment).to eq(new_d)
    end
  end

  describe "#env_vars_hash" do
    it "returns secrets as a hash" do
      project = create(:project)
      create(:secret, project: project, key: "FOO", value: "bar")
      expect(project.env_vars_hash).to eq({ "FOO" => "bar" })
    end
  end

  describe "#analysis_complete?" do
    it "returns true when status is complete and result is present" do
      project = create(:project,
        analysis_status: "complete",
        analysis_result: { "framework" => "rails" }
      )
      expect(project.analysis_complete?).to be true
    end

    it "returns false when status is complete but result is nil" do
      project = create(:project, analysis_status: "complete", analysis_result: nil)
      expect(project.analysis_complete?).to be false
    end

    it "returns false when status is not complete" do
      project = create(:project, analysis_status: "analyzing")
      expect(project.analysis_complete?).to be false
    end
  end

  describe "#analysis_fresh?" do
    it "returns true when complete and analyzed within 2 hours" do
      project = create(:project,
        analysis_status: "complete",
        analysis_result: { "framework" => "rails" },
        analyzed_at:     30.minutes.ago
      )
      expect(project.analysis_fresh?).to be true
    end

    it "returns false when analyzed more than 2 hours ago" do
      project = create(:project,
        analysis_status: "complete",
        analysis_result: { "framework" => "rails" },
        analyzed_at:     3.hours.ago
      )
      expect(project.analysis_fresh?).to be false
    end

    it "returns false when analysis is not complete" do
      project = create(:project, analysis_status: "analyzing", analyzed_at: 5.minutes.ago)
      expect(project.analysis_fresh?).to be false
    end

    it "returns false when analyzed_at is nil" do
      project = create(:project,
        analysis_status: "complete",
        analysis_result: { "framework" => "rails" },
        analyzed_at:     nil
      )
      expect(project.analysis_fresh?).to be false
    end
  end

  describe "#detected_env_vars" do
    it "returns the list from analysis_result" do
      vars = [{ "key" => "DATABASE_URL", "required" => true, "source" => "database" }]
      project = create(:project,
        analysis_status: "complete",
        analysis_result: { "detected_env_vars" => vars }
      )
      expect(project.detected_env_vars).to eq(vars)
    end

    it "returns empty array when analysis is not complete" do
      project = create(:project, analysis_status: "pending")
      expect(project.detected_env_vars).to eq([])
    end

    it "returns empty array when detected_env_vars key is missing from result" do
      project = create(:project,
        analysis_status: "complete",
        analysis_result: { "framework" => "rails" }
      )
      expect(project.detected_env_vars).to eq([])
    end
  end

  describe "#missing_required_secrets" do
    let(:project) do
      create(:project,
        analysis_status: "complete",
        analysis_result: {
          "detected_env_vars" => [
            { "key" => "DATABASE_URL",   "required" => true  },
            { "key" => "OPENAI_API_KEY", "required" => true  },
            { "key" => "SENTRY_DSN",     "required" => false }
          ]
        }
      )
    end

    it "returns required keys that have no matching secret" do
      expect(project.missing_required_secrets).to contain_exactly("DATABASE_URL", "OPENAI_API_KEY")
    end

    it "excludes keys that already have a secret" do
      create(:secret, project: project, key: "DATABASE_URL", value: "postgres://...")
      expect(project.missing_required_secrets).to contain_exactly("OPENAI_API_KEY")
    end

    it "returns empty when all required secrets are set" do
      create(:secret, project: project, key: "DATABASE_URL",   value: "postgres://...")
      create(:secret, project: project, key: "OPENAI_API_KEY", value: "sk-...")
      expect(project.missing_required_secrets).to be_empty
    end

    it "never includes optional vars regardless of whether they are set" do
      project2 = create(:project,
        analysis_status: "complete",
        analysis_result: { "detected_env_vars" => [{ "key" => "SENTRY_DSN", "required" => false }] }
      )
      expect(project2.missing_required_secrets).to be_empty
    end
  end
end
