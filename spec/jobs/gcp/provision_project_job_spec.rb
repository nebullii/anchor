require "rails_helper"

RSpec.describe Gcp::ProvisionProjectJob, type: :job do
  let(:project)  { create(:project) }
  let(:provider) { instance_double(Providers::GcpCloudRun) }

  before { allow(Providers).to receive(:for).with(project).and_return(provider) }

  it "delegates to the provider" do
    expect(provider).to receive(:provision!)
    described_class.perform_now(project.id)
  end

  it "skips local docker projects" do
    local = create(:project, provider: "local_docker", gcp_project_id: nil)
    expect(Providers).not_to receive(:for).with(local)
    described_class.perform_now(local.id)
  end

  it "skips already provisioned projects" do
    project.update!(gcp_provisioned: true)
    expect(provider).not_to receive(:provision!)
    described_class.perform_now(project.id)
  end

  it "records permanent errors without retrying" do
    allow(provider).to receive(:provision!).and_raise(Providers::Error, "PERMISSION_DENIED")
    expect { described_class.perform_now(project.id) }.not_to raise_error
    expect(project.reload.gcp_provision_error).to eq("PERMISSION_DENIED")
  end

  it "re-raises transient errors so Sidekiq retries" do
    allow(provider).to receive(:provision!).and_raise(Providers::TransientError, "503")
    expect { described_class.perform_now(project.id) }.to raise_error(Providers::TransientError)
  end
end
