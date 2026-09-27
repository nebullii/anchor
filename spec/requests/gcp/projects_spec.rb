require "rails_helper"

# Migrated from test/controllers/gcp/projects_controller_test.rb
RSpec.describe "Gcp::Projects", type: :request do
  let(:gcp_project_id) { "my-project-123" }
  let(:sa_email)       { "anchor-deploy@my-project-123.iam.gserviceaccount.com" }
  let(:json)           { { "Content-Type" => "application/json" } }
  let(:iam_base)       { "https://iam.googleapis.com/v1/projects/#{gcp_project_id}/serviceAccounts" }

  let!(:user) do
    User.create!(
      github_id:               "9999",
      github_login:            "testuser",
      name:                    "Test User",
      email:                   "test@example.com",
      github_token:            "gh_token",
      google_email:            "test@example.com",
      google_access_token:     "ya29.test_token",
      google_refresh_token:    "1//refresh_token",
      google_token_expires_at: 1.hour.from_now
    )
  end

  describe "GET /gcp/projects" do
    it "redirects to root when not logged in" do
      get gcp_projects_path
      expect(response).to redirect_to(root_path)
    end

    it "renders the project list when Google is connected" do
      sign_in_via_github(user)
      stub_gcp_projects_list

      get gcp_projects_path

      expect(response).to have_http_status(:success)
      page = Nokogiri::HTML(response.body)
      expect(page.css("input[type=radio][name=gcp_project_id]").size).to eq(2)
      expect(response.body).to include("My Project", "my-project-123")
    end

    it "redirects with an alert when the API call fails" do
      sign_in_via_github(user)
      stub_request(:get, "https://cloudresourcemanager.googleapis.com/v1/projects")
        .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
        .to_return(status: 403, body: '{"error":"forbidden"}', headers: json)

      get gcp_projects_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/Could not list/)
    end

    it "shows an empty state when no projects are returned" do
      sign_in_via_github(user)
      stub_gcp_projects_list(projects: [])

      get gcp_projects_path

      expect(response).to have_http_status(:success)
      page = Nokogiri::HTML(response.body)
      expect(page.css("input[type=radio]")).to be_empty
      expect(page.css("p").map(&:text).join).to match(/No active GCP projects/)
    end
  end

  describe "POST /gcp/projects" do
    before { sign_in_via_github(user) }

    it "creates a service account and redirects to root on success" do
      stub_service_account_creation(project_id: gcp_project_id, email: sa_email)

      post gcp_projects_path, params: { gcp_project_id: gcp_project_id }

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to match(/connected/)
      user.reload
      expect(user.default_gcp_project_id).to eq(gcp_project_id)
      expect(user.gcp_service_account_email).to eq(sa_email)
      expect(user).to be_gcp_configured
    end

    it "stores the encrypted service account key on the user" do
      stub_service_account_creation(project_id: gcp_project_id, email: sa_email)

      post gcp_projects_path, params: { gcp_project_id: gcp_project_id }

      expect(user.reload.gcp_service_account_key).to include("service_account")
    end

    it "redirects back with an alert when project_id is blank" do
      post gcp_projects_path, params: { gcp_project_id: "" }

      expect(response).to redirect_to(gcp_projects_path)
      expect(flash[:alert]).to match(/select a GCP project/)
    end

    it "redirects back with an alert when service account creation fails" do
      stub_request(:get, "#{iam_base}/#{sa_email}").to_return(status: 404, body: "{}", headers: json)
      stub_request(:post, iam_base).to_return(status: 403, body: '{"error":"forbidden"}', headers: json)

      post gcp_projects_path, params: { gcp_project_id: gcp_project_id }

      expect(response).to redirect_to(gcp_projects_path)
      expect(flash[:alert]).to match(/Failed to set up/)
    end

    it "does not update user credentials on failure" do
      stub_request(:get, "#{iam_base}/#{sa_email}").to_return(status: 404, body: "{}", headers: json)
      stub_request(:post, iam_base).to_return(status: 500, body: '{"error":"error"}', headers: json)

      post gcp_projects_path, params: { gcp_project_id: gcp_project_id }

      user.reload
      expect(user.gcp_service_account_email).to be_nil
      expect(user).not_to be_gcp_configured
    end
  end
end
