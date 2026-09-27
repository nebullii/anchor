require "rails_helper"

RSpec.describe "Deploy wizard", type: :request do
  let(:user)       { create(:user, google_access_token: nil, google_token_expires_at: nil) }
  let(:repository) { create(:repository, user: user) }
  let(:project) do
    create(:project, user: user, repository: repository, draft: true, gcp_project_id: nil,
           analysis_status: "complete",
           analysis_result: { "framework" => "docker", "port" => 8000, "has_dockerfile" => true, "detected_env_vars" => [] })
  end

  before { sign_in_via_github(user) }

  describe "GET /wizard" do
    it "shows an actionable empty state when no repositories are synced" do
      get wizard_path

      expect(response.body).to include("No repositories yet", "Sync from GitHub", "Local Docker")
    end
  end

  # The Platform migration adds projects.provider. Until it lands, the wizard
  # must behave exactly as before (Cloud Run only).
  context "before the provider column exists" do
    before do
      skip "provider column present (Platform migration merged)" if Project.column_names.include?("provider")
    end

    it "offers Cloud Run only" do
      get wizard_configure_path(project)

      expect(response.body).not_to include('data-testid="provider-choice"')
      expect(response.body).to include("Google Cloud Run")
    end

    it "still requires GCP credentials to launch" do
      expect {
        post wizard_launch_path(project), params: { provider: "local_docker" }
      }.not_to change(Deployment, :count)

      expect(response).to redirect_to(wizard_configure_path(project))
      expect(flash[:alert]).to include("GCP credentials are required")
    end
  end

  context "with the provider column (Platform contract)" do
    include_context "with provider column"

    it "lets the user choose Local Docker or Google Cloud Run" do
      get wizard_configure_path(project)

      choice = Nokogiri::HTML(response.body).at_css("[data-testid=provider-choice]")
      expect(choice).to be_present
      values = choice.css("input[type=radio][name=provider]").map { |i| i["value"] }
      expect(values).to eq(%w[local_docker gcp_cloud_run])
      expect(choice.text).to include("Local Docker", "Free", "Google Cloud Run")
      # GCP credential fields hide (CSS only) while Local Docker is checked.
      expect(choice.at_css("input[value=local_docker]")["class"]).to include("provider-local")
      expect(response.body).to include("group-has-[.provider-local:checked]/wizard:hidden")
    end

    it "preselects Local Docker for users without GCP credentials" do
      get wizard_configure_path(project)

      checked = Nokogiri::HTML(response.body).at_css("input[name=provider][checked]")
      expect(checked["value"]).to eq("local_docker")
    end

    it "preselects Cloud Run for users with GCP connected" do
      user.update!(google_access_token: "ya29.token", google_token_expires_at: 1.hour.from_now)

      get wizard_configure_path(project)

      checked = Nokogiri::HTML(response.body).at_css("input[name=provider][checked]")
      expect(checked["value"]).to eq("gcp_cloud_run")
    end

    it "launches a Local Docker deploy without any GCP credentials or provisioning" do
      expect {
        post wizard_launch_path(project), params: { provider: "local_docker", secrets: { "GREETING" => "hi" } }
      }.to change(Deployment, :count).by(1)
        .and have_enqueued_job(DeploymentJob)

      expect(Gcp::ProvisionProjectJob).not_to have_been_enqueued
      project.reload
      expect(project.provider).to eq("local_docker")
      expect(project.draft).to be(false)
      expect(project.secrets.find_by(key: "GREETING").value).to eq("hi")
      expect(response).to redirect_to(project_deployment_path(project, Deployment.last))
      expect(flash[:notice]).to include("local Docker")
    end

    it "still requires GCP credentials for Cloud Run" do
      expect {
        post wizard_launch_path(project), params: { provider: "gcp_cloud_run" }
      }.not_to change(Deployment, :count)

      expect(flash[:alert]).to include("choose Local Docker")
    end

    it "ignores unknown provider values and falls back to Cloud Run" do
      post wizard_launch_path(project), params: { provider: "aws_lambda" }

      expect(flash[:alert]).to include("GCP credentials are required")
      expect(project.reload.provider).to eq("gcp_cloud_run")
    end
  end

  describe "POST /wizard/:id/launch with a bad service account key" do
    it "rejects invalid JSON" do
      post wizard_launch_path(project), params: { gcp_service_account_key: "{not json" }

      expect(response).to redirect_to(wizard_configure_path(project))
      expect(flash[:alert]).to include("Invalid JSON")
    end
  end
end
