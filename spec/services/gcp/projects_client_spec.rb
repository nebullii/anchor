require "rails_helper"

# Migrated from test/services/gcp/projects_client_test.rb
RSpec.describe Gcp::ProjectsClient do
  let(:access_token) { "ya29.test_token" }
  let(:client)       { described_class.new(access_token) }
  let(:url)          { "https://cloudresourcemanager.googleapis.com/v1/projects" }

  it "returns the list of active projects" do
    stub_gcp_projects_list

    projects = client.list

    expect(projects.length).to eq(2)
    expect(projects.first).to include(id: "my-project-123", name: "My Project", number: "111")
  end

  it "returns an empty array when no projects exist" do
    stub_gcp_projects_list(projects: [])

    expect(client.list).to be_empty
  end

  it "sends the access token as a Bearer Authorization header" do
    stub_gcp_projects_list

    client.list

    expect(
      a_request(:get, url)
        .with(headers: { "Authorization" => "Bearer #{access_token}" },
              query:   hash_including("filter" => "lifecycleState:ACTIVE"))
    ).to have_been_made
  end

  it "filters by ACTIVE lifecycle state" do
    stub_gcp_projects_list

    client.list

    expect(a_request(:get, url).with(query: hash_including("filter" => "lifecycleState:ACTIVE"))).to have_been_made
  end

  it "raises ApiError on a non-200 response" do
    stub_gcp_projects_list(status: 403)

    expect { client.list }.to raise_error(Gcp::ApiError)
  end

  it "raises ApiError on network failure" do
    stub_request(:get, url)
      .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
      .to_raise(Faraday::ConnectionFailed.new("connection refused"))

    expect { client.list }.to raise_error(Gcp::ApiError)
  end

  it "handles a response without a projects key" do
    stub_request(:get, url)
      .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

    expect(client.list).to be_empty
  end
end
