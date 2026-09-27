require "rails_helper"

RSpec.describe "Deployments", type: :request do
  let(:user)       { create(:user) }
  let(:repository) { create(:repository, user: user) }
  let(:project)    { create(:project, user: user, repository: repository) }

  # Rack::Attack counts requests in a shared Redis in the test env; keep these
  # specs independent of whatever ran before them.
  around do |example|
    enabled = Rack::Attack.enabled
    Rack::Attack.enabled = false
    example.run
  ensure
    Rack::Attack.enabled = enabled
  end

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  describe "POST /projects/:project_id/deployments" do
    it "creates a queued deployment, enqueues the pipeline and consumes quota" do
      expect {
        post project_deployments_path(project)
      }.to change(project.deployments, :count).by(1)
        .and have_enqueued_job(DeploymentJob)

      deployment = project.deployments.last
      expect(deployment.status).to eq("queued")
      expect(deployment.triggered_by).to eq("manual")
      expect(response).to redirect_to(project_deployment_path(project, deployment))
      expect(user.reload.deployments_today).to eq(1)
    end

    it "refuses when a deployment is already in progress" do
      create(:deployment, :building, project: project)

      expect {
        post project_deployments_path(project)
      }.not_to change(Deployment, :count)
      expect(flash[:alert]).to match(/already in progress/)
      expect(user.reload.deployments_today).to eq(0)
    end

    it "refuses when the daily quota is used up" do
      user.update_columns(deployments_today: User::DAILY_DEPLOY_LIMIT, quota_reset_at: 1.hour.from_now)

      expect {
        post project_deployments_path(project)
      }.not_to change(Deployment, :count)
      expect(flash[:alert]).to match(/quota reached \(20\/day\)/)
      expect(user.reload.deployments_today).to eq(User::DAILY_DEPLOY_LIMIT)
    end

    it "refuses when required secrets are missing, without consuming quota" do
      project.update!(analysis_status: "complete", analysis_result: {
        "detected_env_vars" => [ { "key" => "DATABASE_URL", "required" => true } ]
      })

      expect {
        post project_deployments_path(project)
      }.not_to change(Deployment, :count)
      expect(response).to redirect_to(project_secrets_path(project))
      expect(user.reload.deployments_today).to eq(0)
    end

    it "refunds quota when it loses the race for the active-deployment slot" do
      # Simulate a concurrent request creating a deployment between our
      # has_active_deployment? check and our INSERT.
      allow_any_instance_of(Project).to receive(:has_active_deployment?).and_return(false)
      create(:deployment, :analyzing, project: project)

      expect {
        post project_deployments_path(project)
      }.not_to have_enqueued_job(DeploymentJob)
      expect(flash[:alert]).to match(/already in progress/)
      expect(user.reload.deployments_today).to eq(0)
    end

    it "404s for another user's project" do
      other = create(:project)
      post project_deployments_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /projects/:project_id/deployments/:id/cancel" do
    it "cancels an in-progress deployment" do
      deployment = create(:deployment, :building, project: project)

      post cancel_project_deployment_path(project, deployment)

      expect(deployment.reload.status).to eq("cancelled")
      expect(flash[:notice]).to eq("Deployment cancelled.")
      expect(deployment.deployment_logs.pluck(:message).join).to include("cancelled by")
    end

    it "calls the provider to stop the build when available" do
      deployment = create(:deployment, :building, project: project)
      provider = double("provider")
      stub_const("Providers", Module.new { def self.for(_project) = nil })
      allow(Providers).to receive(:for).and_return(provider)
      expect(provider).to receive(:cancel_build!)

      post cancel_project_deployment_path(project, deployment)
    end

    it "refuses to cancel a finished deployment" do
      deployment = create(:deployment, :running, project: project)

      post cancel_project_deployment_path(project, deployment)

      expect(deployment.reload.status).to eq("running")
      expect(flash[:alert]).to match(/already running and cannot be cancelled/)
    end
  end
end
