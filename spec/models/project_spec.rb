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
  end

  describe "#latest_deployment" do
    it "returns the most recent deployment" do
      project = create(:project)
      old_d = create(:deployment, project: project, created_at: 1.hour.ago)
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
end
