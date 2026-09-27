require "rails_helper"

RSpec.describe "db/seeds.rb" do
  include ActiveJob::TestHelper

  def seed!
    expect { Rails.application.load_seed }.to output(/Seeded demo user/).to_stdout
  end

  it "creates the demo user the dev login signs in as" do
    seed!

    user = User.find_by(github_id: DashboardController::DEV_LOGIN_GITHUB_ID)
    expect(user).to be_present
    expect(user.github_login).to eq("demo")
    expect(user.github_token).to be_blank
  end

  it "creates a ready-to-deploy demo project on a tiny public repo" do
    seed!

    project = User.find_by(github_id: "anchor-demo").projects.sole
    expect(project.name).to eq("hello-anchor")
    expect(project.draft).to be(false)
    expect(project.analysis_complete?).to be(true)
    expect(project.missing_required_secrets).to be_empty
    expect(project.repository.private).to be(false)
    expect(project.repository.clone_url).to start_with("https://github.com/")
    expect(project.production_branch).to eq(project.repository.default_branch)
  end

  it "does not enqueue GCP provisioning for the demo project" do
    seed!
    expect(Gcp::ProvisionProjectJob).not_to have_been_enqueued
  end

  it "is idempotent" do
    seed!
    seed!

    expect(User.where(github_id: "anchor-demo").count).to eq(1)
    expect(Repository.where(github_id: "anchor-demo-sample").count).to eq(1)
    expect(Project.where(name: "hello-anchor").count).to eq(1)
  end

  context "with the provider column" do
    include_context "with provider column"

    it "uses the Local Docker provider" do
      seed!
      expect(Project.find_by(name: "hello-anchor").provider).to eq("local_docker")
    end
  end

  it "never runs in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect { Rails.application.load_seed }.not_to change(User, :count)
  end
end
