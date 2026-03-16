require "rails_helper"

RSpec.describe Deployment, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:deployment_logs).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:status) }
  end

  describe "scopes" do
    let(:project) { create(:project) }

    it ".in_progress returns non-terminal deployments" do
      # Each in-progress deployment must use a different project (unique partial index).
      project2  = create(:project, user: project.user, repository: project.repository)
      pending_d = create(:deployment, project: project, status: "pending")
      cloning   = create(:deployment, :cloning, project: project2)
      success   = create(:deployment, :success, project: project)

      expect(Deployment.in_progress).to include(pending_d, cloning)
      expect(Deployment.in_progress).not_to include(success)
    end

    it ".terminal returns only finished deployments" do
      create(:deployment, project: project, status: "pending")
      success = create(:deployment, :success, project: project)
      failed  = create(:deployment, :failed, project: project)

      expect(project.deployments.terminal).to contain_exactly(success, failed)
    end
  end

  describe "#in_progress?" do
    it "returns true for active statuses" do
      %w[queued pending analyzing cloning detecting building deploying health_check].each do |s|
        expect(build(:deployment, status: s).in_progress?).to be true
      end
    end

    it "returns false for terminal statuses" do
      %w[running success failed cancelled].each do |s|
        expect(build(:deployment, status: s).in_progress?).to be false
      end
    end
  end

  describe "#terminal?" do
    it "returns true for success, failed, cancelled" do
      %w[running success failed cancelled].each do |s|
        expect(build(:deployment, status: s).terminal?).to be true
      end
    end
  end

  describe "#success?" do
    it "returns true for running and success" do
      expect(build(:deployment, status: "running")).to be_success
      expect(build(:deployment, status: "success")).to be_success
    end
  end

  describe "#duration_label" do
    it "formats duration as minutes and seconds" do
      deployment = build(:deployment,
        started_at: 150.seconds.ago,
        finished_at: Time.current)
      expect(deployment.duration_label).to eq("2m 30s")
    end

    it "returns a dash when not finished" do
      deployment = build(:deployment, started_at: Time.current, finished_at: nil)
      expect(deployment.duration_label).to eq("—")
    end
  end

  describe "#append_log" do
    it "creates a deployment log record" do
      deployment = create(:deployment)
      expect {
        deployment.append_log("Build started", level: "info")
      }.to change(DeploymentLog, :count).by(1)
    end

    it "stores the message and level" do
      deployment = create(:deployment)
      log = deployment.append_log("Something went wrong", level: "error")
      expect(log.message).to eq("Something went wrong")
      expect(log.level).to eq("error")
    end
  end

  describe "#transition_to!" do
    it "updates the status" do
      deployment = create(:deployment, status: "pending")
      deployment.transition_to!("cloning")
      expect(deployment.reload.status).to eq("cloning")
    end

    it "sets started_at when entering cloning" do
      deployment = create(:deployment, status: "pending")
      deployment.transition_to!("cloning")
      expect(deployment.reload.started_at).to be_within(2.seconds).of(Time.current)
    end

    it "sets finished_at on terminal states" do
      deployment = create(:deployment, :building)
      deployment.transition_to!("success")
      expect(deployment.reload.finished_at).to be_within(2.seconds).of(Time.current)
    end

    it "raises on unknown status" do
      deployment = create(:deployment)
      expect { deployment.transition_to!("bogus") }.to raise_error(ArgumentError)
    end
  end
end
