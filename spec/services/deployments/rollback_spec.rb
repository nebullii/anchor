require "rails_helper"

RSpec.describe Deployments::Rollback do
  include ActiveJob::TestHelper

  let(:user)    { create(:user) }
  let(:project) { create(:project, user: user) }

  def live(rev, at:, status: "running", **attrs)
    create(:deployment, project: project, status: status, revision_name: rev,
           revision_url: "https://#{rev}.run.app", service_url: "https://svc.run.app",
           commit_sha: "sha-#{rev}", commit_message: "commit #{rev}",
           created_at: at, finished_at: at, **attrs)
  end

  let!(:older)   { live("rev-1", at: 3.hours.ago) }
  let!(:broken)  { create(:deployment, :failed, project: project, created_at: 2.hours.ago) }
  let!(:current) { live("rev-2", at: 1.hour.ago) }

  before { ActiveJob::Base.queue_adapter = :test }

  describe ".current_deployment / .default_target" do
    it "picks the live deployment and the previous healthy revision" do
      expect(described_class.current_deployment(project)).to eq(current)
      expect(described_class.default_target(project)).to eq(older)
    end

    it "skips older deployments that share the live revision" do
      live("rev-2", at: 2.5.hours.ago, status: "success")
      expect(described_class.default_target(project)).to eq(older)
    end
  end

  describe "#call" do
    it "creates a queued rollback deployment for the previous revision and enqueues RollbackJob" do
      deployment = nil
      expect {
        deployment = described_class.new(project: project, user: user).call
      }.to change(project.deployments, :count).by(1)

      expect(deployment).to have_attributes(
        status: "queued", triggered_by: "rollback",
        revision_name: "rev-1", revision_url: "https://rev-1.run.app", commit_sha: "sha-rev-1"
      )
      expect(deployment.commit_message).to start_with("Rollback to ##{older.id}")
      expect(Deployments::RollbackJob).to have_been_enqueued.with(deployment.id)
    end

    it "accepts an explicit target by id" do
      rev0 = live("rev-0", at: 5.hours.ago, status: "rolled_back")
      deployment = described_class.new(project: project, target: rev0.id.to_s, user: user).call
      expect(deployment.revision_name).to eq("rev-0")
    end

    it "rejects targets that never went live" do
      expect { described_class.new(project: project, target: broken, user: user).call }
        .to raise_error(described_class::Error, /never went live/)
    end

    it "rejects the revision that is already live" do
      expect { described_class.new(project: project, target: current, user: user).call }
        .to raise_error(described_class::Error, /already serving/)
    end

    it "rejects targets from another project" do
      other = create(:deployment, status: "running", revision_name: "x")
      expect { described_class.new(project: project, target: other.id, user: user).call }
        .to raise_error(described_class::Error, /not found/)
    end

    it "refuses while another deployment is in progress" do
      create(:deployment, :building, project: project)
      expect { described_class.new(project: project, user: user).call }
        .to raise_error(described_class::Error, /in progress/)
    end

    it "errors when there is nothing to roll back to" do
      older.update_columns(revision_name: nil)
      expect { described_class.new(project: project, user: user).call }
        .to raise_error(described_class::Error, /No previous healthy deployment/)
    end
  end

  describe ".eligible?" do
    it "is true only for previous healthy revisions when nothing is in progress" do
      expect(described_class.eligible?(older)).to be(true)
      expect(described_class.eligible?(current)).to be(false)
      expect(described_class.eligible?(broken)).to be(false)

      create(:deployment, :building, project: project)
      expect(described_class.eligible?(older)).to be(false)
    end
  end
end
