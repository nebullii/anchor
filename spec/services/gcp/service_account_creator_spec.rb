require "rails_helper"

# Migrated from test/services/gcp/service_account_creator_test.rb
RSpec.describe Gcp::ServiceAccountCreator do
  let(:project_id)   { "my-project-123" }
  let(:access_token) { "ya29.test_token" }
  let(:sa_email)     { "anchor-deploy@my-project-123.iam.gserviceaccount.com" }
  let(:json)         { { "Content-Type" => "application/json" } }
  let(:iam_base)     { "https://iam.googleapis.com/v1/projects/#{project_id}/serviceAccounts" }
  let(:crm_base)     { "https://cloudresourcemanager.googleapis.com/v1/projects/#{project_id}" }

  subject(:creator) { described_class.new(project_id, access_token) }

  def stub_sa_missing
    stub_request(:get, "#{iam_base}/#{sa_email}").to_return(status: 404, body: "{}", headers: json)
  end

  def stub_sa_created
    stub_request(:post, iam_base).to_return(status: 200, body: { "email" => sa_email }.to_json, headers: json)
  end

  def stub_policy_get_and_set
    stub_request(:post, "#{crm_base}:getIamPolicy")
      .to_return(status: 200, body: { "bindings" => [], "etag" => "abc" }.to_json, headers: json)
    stub_request(:post, "#{crm_base}:setIamPolicy")
      .to_return(status: 200, body: { "bindings" => [] }.to_json, headers: json)
  end

  it "returns the email and decoded key_json on success" do
    stub_service_account_creation(project_id: project_id, email: sa_email)

    result = creator.call

    expect(result[:email]).to eq(sa_email)
    expect(result[:key_json]).to include("service_account", project_id)
  end

  it "reuses an existing service account instead of creating one" do
    stub_request(:get, "#{iam_base}/#{sa_email}")
      .to_return(status: 200, body: { "email" => sa_email }.to_json, headers: json)
    stub_policy_get_and_set
    stub_request(:post, "#{iam_base}/#{sa_email}/keys")
      .to_return(
        status: 200,
        body: { "privateKeyData" => Base64.encode64('{"type":"service_account"}'), "keyAlgorithm" => "KEY_ALG_RSA_2048" }.to_json,
        headers: json
      )

    result = creator.call

    expect(result[:email]).to eq(sa_email)
    expect(a_request(:post, iam_base)).not_to have_been_made
  end

  it "binds all required IAM roles" do
    set_policy_body = nil
    stub_service_account_creation(project_id: project_id, email: sa_email)
    # Override the setIamPolicy stub to capture the request body
    stub_request(:post, "#{crm_base}:setIamPolicy").to_return do |request|
      set_policy_body = JSON.parse(request.body)
      { status: 200, body: { "bindings" => [] }.to_json, headers: json }
    end

    creator.call

    granted_roles = set_policy_body.dig("policy", "bindings").map { |b| b["role"] }
    expect(granted_roles).to include(*described_class::REQUIRED_ROLES)
  end

  it "raises ApiError when service account creation fails" do
    stub_sa_missing
    stub_request(:post, iam_base).to_return(status: 403, body: '{"error":"forbidden"}', headers: json)

    expect { creator.call }.to raise_error(Gcp::ApiError)
  end

  it "raises ApiError when the IAM policy fetch fails" do
    stub_sa_missing
    stub_sa_created
    stub_request(:post, "#{crm_base}:getIamPolicy").to_return(status: 403, body: '{"error":"forbidden"}', headers: json)

    expect { creator.call }.to raise_error(Gcp::ApiError)
  end

  it "raises ApiError when key creation fails" do
    stub_sa_missing
    stub_sa_created
    stub_policy_get_and_set
    stub_request(:post, "#{iam_base}/#{sa_email}/keys").to_return(status: 500, body: '{"error":"internal"}', headers: json)

    expect { creator.call }.to raise_error(Gcp::ApiError)
  end
end
