ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# Disable all real HTTP in tests.
WebMock.disable_net_connect!(allow_localhost: true)

# OmniAuth test mode — prevents real OAuth redirects.
OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    # Do not load fixtures globally — service tests are DB-free.
    # Controller tests that need a user create one in setup.

    # Builds a minimal User instance without hitting the DB.
    def build_user(overrides = {})
      User.new({
        github_id:    "123",
        github_login: "testuser",
        github_token: "gh_token",
        name:         "Test User",
        email:        "test@example.com",
        google_email:            "test@example.com",
        google_access_token:     "ya29.test_token",
        google_refresh_token:    "1//refresh_token",
        google_token_expires_at: 1.hour.from_now
      }.merge(overrides))
    end

    # Stubs a successful Google CRM projects list response.
    def stub_gcp_projects_list(projects: nil, status: 200)
      projects ||= [
        { "projectId" => "my-project-123", "name" => "My Project", "projectNumber" => "111" },
        { "projectId" => "other-project",  "name" => "Other",      "projectNumber" => "222" }
      ]

      stub_request(:get, "https://cloudresourcemanager.googleapis.com/v1/projects")
        .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
        .to_return(
          status: status,
          body:   { "projects" => projects }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    # Stubs GCP IAM / CRM calls needed for service account creation.
    def stub_service_account_creation(project_id: "my-project-123", email: "anchor-deploy@my-project-123.iam.gserviceaccount.com")
      # SA already exists check (returns 404 → triggers create)
      stub_request(:get, "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts/#{email}")
        .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

      # Create SA
      stub_request(:post, "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts")
        .to_return(
          status: 200,
          body:   { "email" => email, "name" => "projects/#{project_id}/serviceAccounts/#{email}" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Get IAM policy
      stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{project_id}:getIamPolicy")
        .to_return(
          status: 200,
          body:   { "bindings" => [], "etag" => "abc123", "version" => 1 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Set IAM policy
      stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{project_id}:setIamPolicy")
        .to_return(
          status: 200,
          body:   { "bindings" => [], "etag" => "def456" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Create key
      stub_request(:post, "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts/#{email}/keys")
        .to_return(
          status: 200,
          body:   {
            "privateKeyData" => Base64.encode64('{"type":"service_account","project_id":"my-project-123"}'),
            "keyAlgorithm"   => "KEY_ALG_RSA_2048"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
  end
end
