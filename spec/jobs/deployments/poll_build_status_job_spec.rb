require "rails_helper"

RSpec.describe Deployments::PollBuildStatusJob, type: :job do
  include ActiveJob::TestHelper

  let(:project)    { create(:project) }
  let(:deployment) { create(:deployment, :building, project: project, build_ref: "build-123") }
  let(:provider)   { instance_double(Providers::GcpCloudRun) }

  before { allow(Providers).to receive(:for).with(project).and_return(provider) }

  def status(state, detail: nil, log_url: nil)
    Providers::BuildStatus.new(state: state, detail: detail, log_url: log_url)
  end

  it "hands off to the release step on success" do
    allow(provider).to receive(:build_status).with(deployment).and_return(status(:success, log_url: "https://logs"))

    described_class.perform_now(deployment.id, attempt: 1)

    expect(Deployments::DeployToCloudRunJob).to have_been_enqueued.with(deployment.id)
    expect(deployment.reload.cloud_build_log_url).to eq("https://logs")
    expect(deployment.status).to eq("building")
  end

  it "re-enqueues itself with backoff while pending" do
    allow(provider).to receive(:build_status).and_return(status(:pending, detail: "WORKING"))

    described_class.perform_now(deployment.id, attempt: 4)

    expect(described_class).to have_been_enqueued.with(deployment.id, attempt: 5)
    expect(Deployments::DeployToCloudRunJob).not_to have_been_enqueued
  end

  it "fails the deployment with the provider's detail on failure" do
    allow(provider).to receive(:build_status).and_return(status(:failure, detail: "Cloud Build failure: step 0 exited 1"))

    described_class.perform_now(deployment.id)

    expect(deployment.reload.status).to eq("failed")
    expect(deployment.error_message).to eq("Cloud Build failure: step 0 exited 1")
  end

  it "fails after MAX_ATTEMPTS without asking the provider" do
    expect(provider).not_to receive(:build_status)
    described_class.perform_now(deployment.id, attempt: described_class::MAX_ATTEMPTS + 1)
    expect(deployment.reload.error_message).to include("timed out")
  end

  it "schedules a retry on transient provider errors" do
    allow(provider).to receive(:build_status).and_raise(Providers::TransientError, "503")
    expect { described_class.perform_now(deployment.id) }.to have_enqueued_job(described_class)
    expect(deployment.reload.status).to eq("building")
  end

  it "skips when the deployment is no longer building" do
    deployment.update!(status: "cancelled")
    expect(provider).not_to receive(:build_status)
    described_class.perform_now(deployment.id)
  end

  it "accepts payloads from the old pipeline and backfills build_ref" do
    deployment.update!(build_ref: nil)
    allow(provider).to receive(:build_status).and_return(status(:pending))

    described_class.perform_now(deployment.id, "legacy-build-9", attempt: 2)

    expect(deployment.reload.build_ref).to eq("legacy-build-9")
  end
end

RSpec.describe Deployments::BuildImageJob, type: :job do
  it "is a shim that fails in-flight legacy deployments and never builds" do
    deployment = create(:deployment, :analyzing)
    expect(Providers).not_to receive(:for)

    described_class.perform_now(deployment.id, "/tmp/cloudlaunch/1/2")

    expect(deployment.reload.status).to eq("failed")
    expect(deployment.error_message).to include("redeploy")
  end

  it "never deletes paths outside the legacy checkout root" do
    deployment = create(:deployment, :analyzing)
    expect(FileUtils).not_to receive(:rm_rf)
    described_class.perform_now(deployment.id, "/Users/someone")
  end
end
