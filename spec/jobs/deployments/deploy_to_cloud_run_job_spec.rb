require "rails_helper"

RSpec.describe Deployments::DeployToCloudRunJob, type: :job do
  include ActiveJob::TestHelper

  let(:project)    { create(:project) }
  let(:deployment) { create(:deployment, :building, project: project, image_url: "img:1") }
  let(:provider)   { instance_double(Providers::Base) }
  let(:revision)   { Providers::Revision.new(name: "svc-00002-abc", url: "https://tag---svc.a.run.app") }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Providers).to receive(:for).with(project).and_return(provider)
    create(:secret, project: project, key: "API_KEY", value: "s3cret")
  end

  it "creates a revision without traffic, records it and schedules the health check" do
    expect(provider).to receive(:deploy_revision!)
      .with(deployment, env: { "API_KEY" => "s3cret" }, log: kind_of(Proc))
      .and_return(revision)
    expect(provider).not_to receive(:promote!)

    expect { described_class.new.perform(deployment.id) }
      .to have_enqueued_job(Deployments::HealthCheckJob).with(deployment.id, 1, kind_of(Float))

    deployment.reload
    expect(deployment.status).to eq("health_check")
    expect(deployment.revision_name).to eq("svc-00002-abc")
    expect(deployment.revision_url).to eq("https://tag---svc.a.run.app")
    expect(deployment.service_url).to be_nil
  end

  it "streams provider output into the deployment log" do
    allow(provider).to receive(:deploy_revision!) do |_d, log:, **|
      log.call("Deploying container...")
      revision
    end
    described_class.new.perform(deployment.id)
    expect(deployment.deployment_logs.pluck(:message)).to include("Deploying container...")
  end

  it "fails the deployment on a permanent provider error" do
    allow(provider).to receive(:deploy_revision!).and_raise(Providers::Error, "image not found")
    described_class.new.perform(deployment.id)
    expect(deployment.reload.status).to eq("failed")
    expect(deployment.error_message).to include("image not found")
  end

  it "re-raises transient provider errors as Deployments::TransientError" do
    allow(provider).to receive(:deploy_revision!).and_raise(Providers::TransientError, "503 from API")
    expect { described_class.new.perform(deployment.id) }.to raise_error(Deployments::TransientError)
  end

  it "refuses to continue when the provider returns no revision URL" do
    allow(provider).to receive(:deploy_revision!).and_return(Providers::Revision.new(name: "r1", url: nil))
    expect { described_class.new.perform(deployment.id) }.not_to have_enqueued_job(Deployments::HealthCheckJob)
    expect(deployment.reload.status).to eq("failed")
  end

  it "skips deployments that are not building (e.g. cancelled)" do
    deployment.update!(status: "cancelled")
    expect(provider).not_to receive(:deploy_revision!)
    described_class.new.perform(deployment.id)
    expect(deployment.reload.status).to eq("cancelled")
  end
end
