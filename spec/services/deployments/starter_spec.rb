require "rails_helper"

RSpec.describe Deployments::Starter do
  let(:user)    { create(:user) }
  let(:project) { create(:project, user: user, production_branch: "main") }

  def start(**opts)
    described_class.new(project: project, user: user, **opts).call
  end

  it "creates a queued deployment, charges quota and enqueues the job" do
    result = nil
    expect { result = start(triggered_by: "manual") }.to have_enqueued_job(DeploymentJob)

    expect(result).to be_success
    expect(result.deployment).to have_attributes(status: "queued", branch: "main", triggered_by: "manual")
    expect(user.reload.deployments_today).to eq(1)
  end

  it "uses the requested branch" do
    expect(start(branch: "release/1.2").deployment.branch).to eq("release/1.2")
  end

  it "falls back to an accepted trigger when the requested one is not allowed yet" do
    trigger = start(triggered_by: "not-a-trigger").deployment.triggered_by
    expect(Deployment.new(project: project, status: "queued", triggered_by: trigger)).to be_valid
  end

  it "refuses when a deployment is in progress" do
    create(:deployment, :building, project: project)
    result = start
    expect(result).not_to be_success
    expect(result.error_code).to eq(:deploy_in_progress)
  end

  it "refuses when over quota" do
    user.update_columns(deployments_today: User::DAILY_DEPLOY_LIMIT, quota_reset_at: 1.hour.from_now)
    expect(start.error_code).to eq(:quota_exceeded)
  end

  it "refuses when required secrets are missing" do
    project.update_columns(analysis_status: "complete",
                           analysis_result: { "detected_env_vars" => [ { "key" => "SECRET_KEY_BASE", "required" => true } ] })
    result = start
    expect(result.error_code).to eq(:missing_secrets)
    expect(result.missing_secrets).to eq([ "SECRET_KEY_BASE" ])
  end

  it "refuses unsafe branch names without creating anything" do
    %w[-x --exec=sh a..b].push("has space").each do |branch|
      expect(start(branch: branch).error_code).to eq(:invalid_branch)
    end
    expect(project.deployments.count).to eq(0)
  end

  it "turns a lost race on the unique index into deploy_in_progress" do
    allow(project.deployments).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
    allow(project).to receive(:deployments).and_return(project.deployments)
    expect(start.error_code).to eq(:deploy_in_progress)
  end
end
