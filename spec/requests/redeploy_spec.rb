require "rails_helper"

RSpec.describe "Redeploy", type: :request do
  let(:user)    { create(:user) }
  let(:project) { create(:project, user: user) }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  it "opens the new deployment even for a Turbo Stream request" do
    create(:deployment, project: project, status: "failed")

    post redeploy_project_path(project), headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }

    new_deployment = project.deployments.order(:id).last
    expect(new_deployment.status).to eq("queued")
    expect(response).to redirect_to(project_deployment_path(project, new_deployment))
  end
end

RSpec.describe "Deploy button", type: :request do
  let(:user)    { create(:user) }
  let(:project) { create(:project, user: user) }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  it "opens the new deployment from anywhere (e.g. the dashboard card)" do
    post deploy_project_path(project), headers: { "Accept" => "text/vnd.turbo-stream.html, text/html",
                                                  "Referer" => root_url }
    expect(response).to redirect_to(project_deployment_path(project, project.deployments.last))
  end

  it "shows a notice instead of the project-page modal when secrets are missing elsewhere" do
    allow_any_instance_of(Project).to receive(:missing_required_secrets).and_return([ "API_KEY" ])
    post deploy_project_path(project), headers: { "Accept" => "text/vnd.turbo-stream.html, text/html",
                                                  "Referer" => root_url }
    expect(response.body).to include('target="notices"').and include("API_KEY")
  end
end

RSpec.describe Deployments::PlanBuilder, "target" do
  it "names the provider the project actually deploys to" do
    local = create(:project, provider: "local_docker", gcp_project_id: nil)
    plan  = described_class.new(project: local, analysis_result: { "framework" => "node" }, user: local.user).call
    expect(plan["target"]).to eq("Local Docker")
  end
end
