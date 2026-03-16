require "test_helper"

class Gcp::ProjectsControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = true
  PROJECT_ID = "my-project-123".freeze
  SA_EMAIL   = "anchor-deploy@my-project-123.iam.gserviceaccount.com".freeze

  setup do
    @user = User.create!(
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

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  def login_as(user)
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider:    "github",
      uid:         user.github_id,
      info:        { nickname: user.github_login, name: user.name, email: user.email, image: nil },
      credentials: { token: user.github_token }
    )
    post "/auth/github"
    follow_redirect!  # goes to /auth/github/callback
  end

  # --------------------------------------------------------------------------
  # GET /gcp/projects
  # --------------------------------------------------------------------------

  test "redirects to root if not logged in" do
    get gcp_projects_path
    assert_redirected_to root_path
  end

  test "renders project list when Google is connected" do
    login_as(@user)
    stub_gcp_projects_list

    get gcp_projects_path

    assert_response :success
    assert_select "input[type=radio][name=gcp_project_id]", count: 2
    assert_select "div", text: /My Project/
    assert_select "div", text: /my-project-123/
  end

  test "redirects with alert when API call fails" do
    login_as(@user)

    stub_request(:get, "https://cloudresourcemanager.googleapis.com/v1/projects")
      .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
      .to_return(status: 403, body: '{"error":"forbidden"}', headers: { "Content-Type" => "application/json" })

    get gcp_projects_path

    assert_redirected_to root_path
    assert_match(/Could not list/, flash[:alert])
  end

  test "shows empty state when no projects returned" do
    login_as(@user)
    stub_gcp_projects_list(projects: [])

    get gcp_projects_path

    assert_response :success
    assert_select "input[type=radio]", count: 0
    assert_select "p", text: /No active GCP projects/
  end

  # --------------------------------------------------------------------------
  # POST /gcp/projects
  # --------------------------------------------------------------------------

  test "creates service account and redirects to root on success" do
    login_as(@user)
    stub_service_account_creation(project_id: PROJECT_ID, email: SA_EMAIL)

    post gcp_projects_path, params: { gcp_project_id: PROJECT_ID }

    assert_redirected_to root_path
    assert_match(/connected/, flash[:notice])

    @user.reload
    assert_equal PROJECT_ID, @user.default_gcp_project_id
    assert_equal SA_EMAIL,   @user.gcp_service_account_email
    assert @user.gcp_configured?
  end

  test "stores encrypted service account key on user" do
    login_as(@user)
    stub_service_account_creation(project_id: PROJECT_ID, email: SA_EMAIL)

    post gcp_projects_path, params: { gcp_project_id: PROJECT_ID }

    @user.reload
    assert_includes @user.gcp_service_account_key, "service_account"
  end

  test "redirects back with alert when project_id is blank" do
    login_as(@user)

    post gcp_projects_path, params: { gcp_project_id: "" }

    assert_redirected_to gcp_projects_path
    assert_match(/select a GCP project/, flash[:alert])
  end

  test "redirects back with alert when service account creation fails" do
    login_as(@user)

    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}")
      .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts")
      .to_return(status: 403, body: '{"error":"forbidden"}', headers: { "Content-Type" => "application/json" })

    post gcp_projects_path, params: { gcp_project_id: PROJECT_ID }

    assert_redirected_to gcp_projects_path
    assert_match(/Failed to set up/, flash[:alert])
  end

  test "does not update user credentials on failure" do
    login_as(@user)

    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}")
      .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts")
      .to_return(status: 500, body: '{"error":"error"}', headers: { "Content-Type" => "application/json" })

    post gcp_projects_path, params: { gcp_project_id: PROJECT_ID }

    @user.reload
    assert_nil @user.gcp_service_account_email
    refute @user.gcp_configured?
  end
end
