require "rails_helper"

RSpec.describe Providers::LocalDocker, "#health_check_url" do
  let(:project)    { create(:project, provider: "local_docker", gcp_project_id: nil) }
  let(:deployment) { build(:deployment, project: project, revision_url: "http://localhost:49160") }
  let(:provider)   { described_class.new(project, runner: FakeCommandRunner.new) }

  it "returns the revision URL by default" do
    expect(provider.health_check_url(deployment)).to eq("http://localhost:49160")
  end

  it "swaps localhost for ANCHOR_LOCAL_DOCKER_HOST when the worker runs in a container" do
    stub_const("ENV", ENV.to_h.merge("ANCHOR_LOCAL_DOCKER_HOST" => "host.docker.internal"))
    expect(provider.health_check_url(deployment)).to eq("http://host.docker.internal:49160")
  end
end
