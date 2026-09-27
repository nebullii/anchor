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
      deployment = create(:deployment, :health_check)
      deployment.transition_to!("running")
      expect(deployment.reload.finished_at).to be_within(2.seconds).of(Time.current)
    end

    it "stamps status_changed_at" do
      deployment = create(:deployment, :queued)
      deployment.transition_to!("analyzing")
      expect(deployment.reload.status_changed_at).to be_within(2.seconds).of(Time.current)
    end

    it "records a status_changed event" do
      deployment = create(:deployment, :queued)
      expect { deployment.transition_to!("analyzing") }
        .to change { deployment.deployment_events.for_type("status_changed").count }.by(1)
      event = deployment.deployment_events.last
      expect([ event.from_status, event.to_status ]).to eq(%w[queued analyzing])
    end

    it "raises on unknown status" do
      deployment = create(:deployment)
      expect { deployment.transition_to!("bogus") }.to raise_error(ArgumentError)
    end

    it "is idempotent for the current status (no event, no error)" do
      deployment = create(:deployment, :building)
      expect { deployment.transition_to!("building") }.not_to change(DeploymentEvent, :count)
      expect(deployment.reload.status).to eq("building")
    end

    it "sees a status committed by someone else (row lock re-reads the row)" do
      deployment = create(:deployment, :building)
      Deployment.find(deployment.id).update_columns(status: "cancelled")

      # The in-memory copy still says "building", but the locked re-read wins.
      expect { deployment.transition_to!("deploying") }.to raise_error(Deployment::InvalidTransition)
      expect(deployment.reload.status).to eq("cancelled")
    end

    it "takes a row lock" do
      deployment = create(:deployment, :queued)
      expect(deployment).to receive(:with_lock).and_call_original
      deployment.transition_to!("analyzing")
    end
  end

  describe "state machine" do
    let(:project) { create(:project) }

    legal = [
      %w[queued analyzing],
      %w[analyzing building],
      %w[building deploying],
      %w[deploying health_check],
      %w[health_check running],
      %w[health_check rolled_back],
      %w[running rolled_back],
      %w[queued deploying],       # rollback deployments skip the build
      %w[pending cloning],        # legacy pipeline
      %w[cloning detecting],
      %w[detecting building]
    ]
    Deployment::IN_PROGRESS_STATUSES.each do |from|
      legal << [ from, "failed" ] << [ from, "cancelled" ]
    end

    legal.each do |from, to|
      it "allows #{from} → #{to}" do
        deployment = create(:deployment, project: project, status: from)
        expect(deployment.can_transition_to?(to)).to be true
        expect { deployment.transition_to!(to) }.not_to raise_error
        expect(deployment.reload.status).to eq(to)
      end
    end

    [
      %w[queued running],
      %w[queued building],
      %w[analyzing deploying],
      %w[building running],
      %w[building analyzing],
      %w[deploying building],
      %w[running failed],
      %w[running building],
      %w[failed queued],
      %w[failed running],
      %w[cancelled building],
      %w[cancelled failed],
      %w[rolled_back running]
    ].each do |from, to|
      it "rejects #{from} → #{to}" do
        deployment = create(:deployment, project: project, status: from)
        expect(deployment.can_transition_to?(to)).to be false
        expect { deployment.transition_to!(to) }.to raise_error(Deployment::InvalidTransition)
        expect(deployment.reload.status).to eq(from)
      end
    end

    it "has a transition entry for every status" do
      expect(Deployment::TRANSITIONS.keys).to match_array(Deployment::STATUSES)
    end

    it "treats rolled_back as terminal" do
      expect(build(:deployment, status: "rolled_back")).to be_terminal
    end

    it "accepts rollback and cli triggers" do
      expect(build(:deployment, triggered_by: "rollback")).to be_valid
      expect(build(:deployment, triggered_by: "cli")).to be_valid
      expect(build(:deployment, triggered_by: "carrier_pigeon")).not_to be_valid
    end

    it "frees the one-active-deployment slot once rolled back" do
      create(:deployment, project: project, status: "rolled_back")
      expect { create(:deployment, :queued, project: project) }.not_to raise_error
    end

    it "enforces one in-progress deployment per project in the database" do
      create(:deployment, :building, project: project)
      expect { create(:deployment, :queued, project: project) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#cancel!" do
    let(:deployment) { create(:deployment, :building) }

    it "moves the deployment to cancelled and logs why" do
      deployment.cancel!(reason: "Stop please")
      expect(deployment.reload.status).to eq("cancelled")
      expect(deployment.finished_at).to be_present
      expect(deployment.deployment_logs.pluck(:message)).to include("Stop please")
      expect(deployment.deployment_events.for_type("cancelled")).to exist
    end

    it "asks the provider to cancel the remote build" do
      provider = double("provider")
      stub_const("Providers", Module.new { def self.for(_project) = nil })
      allow(Providers).to receive(:for).with(deployment.project).and_return(provider)
      expect(provider).to receive(:cancel_build!).with(deployment)

      deployment.cancel!
    end

    it "still cancels when the provider call fails" do
      provider = double("provider")
      stub_const("Providers", Module.new { def self.for(_project) = nil })
      allow(Providers).to receive(:for).and_return(provider)
      allow(provider).to receive(:cancel_build!).and_raise(StandardError, "api down")

      expect { deployment.cancel! }.not_to raise_error
      expect(deployment.reload.status).to eq("cancelled")
    end

    it "is a no-op when already cancelled" do
      deployment.cancel!
      expect { deployment.cancel! }.not_to change(DeploymentLog, :count)
    end

    it "raises InvalidTransition for a finished deployment" do
      done = create(:deployment, :running)
      expect { done.cancel! }.to raise_error(Deployment::InvalidTransition)
      expect(done.reload.status).to eq("running")
    end
  end

  describe "#fail!" do
    it "fails an in-progress deployment with a categorised error" do
      deployment = create(:deployment, :building)
      expect(deployment.fail!("Cloud Build timeout exceeded")).to be true
      deployment.reload
      expect(deployment.status).to eq("failed")
      expect(deployment.error_message).to eq("Cloud Build timeout exceeded")
      expect(deployment.error_category).to eq("build_timeout")
    end

    it "does not overwrite a cancelled deployment" do
      deployment = create(:deployment, :cancelled)
      expect(deployment.fail!("boom")).to be false
      expect(deployment.reload.status).to eq("cancelled")
      expect(deployment.error_message).to be_nil
    end
  end
end
