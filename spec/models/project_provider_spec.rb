require "rails_helper"

RSpec.describe Project, "provider settings" do
  it "defaults to Cloud Run, public, 512Mi and /" do
    project = create(:project)
    expect(project).to have_attributes(provider: "gcp_cloud_run", public_access: true, memory: "512Mi", health_check_path: "/")
    expect(project).to be_gcp_cloud_run
    expect(project).not_to be_local_docker
  end

  it "rejects unknown providers" do
    expect(build(:project, provider: "heroku")).not_to be_valid
  end

  it "validates memory format" do
    expect(build(:project, memory: "1Gi")).to be_valid
    expect(build(:project, memory: "512")).not_to be_valid
    expect(build(:project, memory: "lots")).not_to be_valid
  end

  it "requires health_check_path to start with /" do
    expect(build(:project, health_check_path: "/healthz")).to be_valid
    expect(build(:project, health_check_path: "healthz")).not_to be_valid
  end

  it "does not need a GCP project id for local docker" do
    expect(build(:project, provider: "local_docker", gcp_project_id: nil)).to be_valid
    expect(build(:project, provider: "gcp_cloud_run", gcp_project_id: nil)).not_to be_valid
  end

  it "only enqueues GCP provisioning for Cloud Run projects" do
    ActiveJob::Base.queue_adapter = :test
    expect { create(:project, provider: "local_docker", gcp_project_id: nil) }
      .not_to have_enqueued_job(Gcp::ProvisionProjectJob)
    expect { create(:project) }.to have_enqueued_job(Gcp::ProvisionProjectJob)
  end
end
