require "test_helper"

class Gcp::ServiceAccountCreatorTest < ActiveSupport::TestCase
  PROJECT_ID   = "my-project-123".freeze
  ACCESS_TOKEN = "ya29.test_token".freeze
  SA_EMAIL     = "anchor-deploy@my-project-123.iam.gserviceaccount.com".freeze

  test "returns email and decoded key_json on success" do
    stub_service_account_creation(project_id: PROJECT_ID, email: SA_EMAIL)

    result = Gcp::ServiceAccountCreator.new(PROJECT_ID, ACCESS_TOKEN).call

    assert_equal SA_EMAIL, result[:email]
    assert_includes result[:key_json], "service_account"
    assert_includes result[:key_json], PROJECT_ID
  end

  test "reuses existing service account if already present" do
    # SA exists → no create call needed
    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}")
      .to_return(
        status: 200,
        body:   { "email" => SA_EMAIL }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{PROJECT_ID}:getIamPolicy")
      .to_return(
        status: 200,
        body:   { "bindings" => [], "etag" => "abc" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{PROJECT_ID}:setIamPolicy")
      .to_return(
        status: 200,
        body:   { "bindings" => [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}/keys")
      .to_return(
        status: 200,
        body:   { "privateKeyData" => Base64.encode64('{"type":"service_account"}'), "keyAlgorithm" => "KEY_ALG_RSA_2048" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = Gcp::ServiceAccountCreator.new(PROJECT_ID, ACCESS_TOKEN).call

    assert_equal SA_EMAIL, result[:email]
    assert_not_requested :post,
                         "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts"
  end

  test "binds all required IAM roles" do
    set_policy_body = nil

    stub_service_account_creation(project_id: PROJECT_ID, email: SA_EMAIL)

    # Override the setIamPolicy stub to capture the request body
    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{PROJECT_ID}:setIamPolicy")
      .to_return do |request|
        set_policy_body = JSON.parse(request.body)
        { status: 200, body: { "bindings" => [] }.to_json, headers: { "Content-Type" => "application/json" } }
      end

    Gcp::ServiceAccountCreator.new(PROJECT_ID, ACCESS_TOKEN).call

    granted_roles = set_policy_body.dig("policy", "bindings").map { |b| b["role"] }

    Gcp::ServiceAccountCreator::REQUIRED_ROLES.each do |role|
      assert_includes granted_roles, role, "Expected role #{role} to be granted"
    end
  end

  test "raises ApiError when service account creation fails" do
    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}")
      .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts")
      .to_return(status: 403, body: '{"error":"forbidden"}', headers: { "Content-Type" => "application/json" })

    assert_raises(Gcp::ApiError) do
      Gcp::ServiceAccountCreator.new(PROJECT_ID, ACCESS_TOKEN).call
    end
  end

  test "raises ApiError when IAM policy fetch fails" do
    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}")
      .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts")
      .to_return(
        status: 200,
        body:   { "email" => SA_EMAIL }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{PROJECT_ID}:getIamPolicy")
      .to_return(status: 403, body: '{"error":"forbidden"}', headers: { "Content-Type" => "application/json" })

    assert_raises(Gcp::ApiError) do
      Gcp::ServiceAccountCreator.new(PROJECT_ID, ACCESS_TOKEN).call
    end
  end

  test "raises ApiError when key creation fails" do
    stub_request(:get, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}")
      .to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts")
      .to_return(
        status: 200,
        body:   { "email" => SA_EMAIL }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{PROJECT_ID}:getIamPolicy")
      .to_return(
        status: 200,
        body:   { "bindings" => [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://cloudresourcemanager.googleapis.com/v1/projects/#{PROJECT_ID}:setIamPolicy")
      .to_return(
        status: 200,
        body:   { "bindings" => [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://iam.googleapis.com/v1/projects/#{PROJECT_ID}/serviceAccounts/#{SA_EMAIL}/keys")
      .to_return(status: 500, body: '{"error":"internal"}', headers: { "Content-Type" => "application/json" })

    assert_raises(Gcp::ApiError) do
      Gcp::ServiceAccountCreator.new(PROJECT_ID, ACCESS_TOKEN).call
    end
  end
end
