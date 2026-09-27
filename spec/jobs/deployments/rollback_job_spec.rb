require "rails_helper"

RSpec.describe Deployments::RollbackJob, type: :job do
  let(:user)     { create(:user) }
  let(:project)  { create(:project, user: user, latest_url: "https://svc.run.app") }
  let(:provider) { instance_double(Providers::Base) }

  let!(:older) do
    create(:deployment, project: project, status: "running", revision_name: "rev-1",
           service_url: "https://svc.run.app", created_at: 2.hours.ago, finished_at: 2.hours.ago)
  end
  let!(:current) do
    create(:deployment, project: project, status: "running", revision_name: "rev-2",
           service_url: "https://svc.run.app", created_at: 1.hour.ago, finished_at: 1.hour.ago)
  end
  let(:rollback) do
    ActiveJob::Base.queue_adapter = :test
    Deployments::Rollback.new(project: project, user: user).call
  end

  before { allow(Providers).to receive(:for).with(project).and_return(provider) }

  it "shifts traffic, marks the rollback running and the previous live deployment rolled_back" do
    expect(provider).to receive(:rollback!).with(project, "rev-1", log: kind_of(Proc)).and_return(nil)

    described_class.new.perform(rollback.id)

    expect(rollback.reload.status).to eq("running")
    expect(rollback.service_url).to eq("https://svc.run.app")
    expect(current.reload.status).to eq("rolled_back")
    expect(older.reload.status).to eq("superseded")
    expect(project.reload.status).to eq("active")
    expect(Deployments::Rollback.current_deployment(project)).to eq(rollback)
  end

  it "uses the URL returned by the provider when there is one" do
    allow(provider).to receive(:rollback!).and_return("https://new.run.app")
    described_class.new.perform(rollback.id)
    expect(rollback.reload.service_url).to eq("https://new.run.app")
    expect(project.reload.latest_url).to eq("https://new.run.app")
  end

  it "fails the rollback and leaves the live deployment alone when the provider errors" do
    allow(provider).to receive(:rollback!).and_raise(Providers::Error, "revision gone")

    described_class.new.perform(rollback.id)

    expect(rollback.reload.status).to eq("failed")
    expect(rollback.error_message).to include("Traffic was not changed")
    expect(current.reload.status).to eq("running")
  end

  it "does nothing for a rollback that is no longer queued" do
    rollback.update_columns(status: "cancelled")
    expect(provider).not_to receive(:rollback!)
    described_class.new.perform(rollback.id)
  end
end
