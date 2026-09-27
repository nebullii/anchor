# WebMock stubs for the Google Cloud REST APIs Anchor calls during GCP
# onboarding. Migrated from the old minitest test_helper.rb.
module GcpStubs
  CRM_PROJECTS_URL = "https://cloudresourcemanager.googleapis.com/v1/projects".freeze
  JSON_HEADERS     = { "Content-Type" => "application/json" }.freeze

  # Stubs a Google CRM projects list response.
  def stub_gcp_projects_list(projects: nil, status: 200)
    projects ||= [
      { "projectId" => "my-project-123", "name" => "My Project", "projectNumber" => "111" },
      { "projectId" => "other-project",  "name" => "Other",      "projectNumber" => "222" }
    ]

    stub_request(:get, CRM_PROJECTS_URL)
      .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
      .to_return(status: status, body: { "projects" => projects }.to_json, headers: JSON_HEADERS)
  end

  # Stubs every IAM / CRM call needed for a fresh service account creation.
  def stub_service_account_creation(project_id: "my-project-123",
                                    email: "anchor-deploy@my-project-123.iam.gserviceaccount.com")
    # SA existence check returns 404 → triggers create
    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts/#{email}")
      .to_return(status: 404, body: "{}", headers: JSON_HEADERS)

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts")
      .to_return(
        status: 200,
        body: { "email" => email, "name" => "projects/#{project_id}/serviceAccounts/#{email}" }.to_json,
        headers: JSON_HEADERS
      )

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{project_id}:getIamPolicy")
      .to_return(status: 200, body: { "bindings" => [], "etag" => "abc123", "version" => 1 }.to_json, headers: JSON_HEADERS)

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{project_id}:setIamPolicy")
      .to_return(status: 200, body: { "bindings" => [], "etag" => "def456" }.to_json, headers: JSON_HEADERS)

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts/#{email}/keys")
      .to_return(
        status: 200,
        body: {
          "privateKeyData" => Base64.encode64('{"type":"service_account","project_id":"my-project-123"}'),
          "keyAlgorithm"   => "KEY_ALG_RSA_2048"
        }.to_json,
        headers: JSON_HEADERS
      )
  end
end

RSpec.configure do |config|
  config.include GcpStubs
end
