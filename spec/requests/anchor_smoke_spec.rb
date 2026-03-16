require "rails_helper"

RSpec.describe "Anchor smoke flow", type: :request do
  let(:user) { create(:user) }
  let(:repository) { create(:repository, user: user, full_name: "acme/fastapi-app") }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  it "supports create -> analyze -> configure env -> queue deployment" do
    expect {
      post projects_path, params: {
        project: {
          name: "FastAPI App",
          repository_id: repository.id,
          gcp_project_id: "acme-dev-123",
          gcp_region: "us-central1",
          production_branch: "main"
        }
      }
    }.to change(Project, :count).by(1)

    project = Project.order(:created_at).last
    expect(project.repository).to eq(repository)
    expect(project.analysis_status).to eq("pending")

    post analyze_project_path(project)
    expect(project.reload.analysis_status).to eq("analyzing")

    project.update!(
      analysis_status: "complete",
      analysis_result: {
        "framework" => "fastapi",
        "runtime" => "python3.11",
        "port" => 8000,
        "has_dockerfile" => false,
        "detected_env_vars" => [
          { "key" => "DATABASE_URL", "required" => true, "source" => "database" }
        ]
      },
      analyzed_at: Time.current
    )

    post project_secrets_path(project), params: {
      secret: {
        key: "DATABASE_URL",
        value: "postgresql://user:pass@localhost/app"
      }
    }
    expect(project.reload.secrets.pluck(:key)).to include("DATABASE_URL")

    expect {
      post deploy_project_path(project)
    }.to change(Deployment, :count).by(1)

    deployment = project.deployments.order(:created_at).last
    expect(deployment.status).to eq("queued")
    expect(deployment.triggered_by).to eq("manual")
  end
end
