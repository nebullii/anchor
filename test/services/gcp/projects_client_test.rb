require "test_helper"

class Gcp::ProjectsClientTest < ActiveSupport::TestCase
  ACCESS_TOKEN = "ya29.test_token".freeze

  test "returns list of active projects" do
    stub_gcp_projects_list

    projects = Gcp::ProjectsClient.new(ACCESS_TOKEN).list

    assert_equal 2, projects.length
    assert_equal "my-project-123", projects.first[:id]
    assert_equal "My Project",     projects.first[:name]
    assert_equal "111",            projects.first[:number]
  end

  test "returns empty array when no projects exist" do
    stub_gcp_projects_list(projects: [])

    projects = Gcp::ProjectsClient.new(ACCESS_TOKEN).list

    assert_empty projects
  end

  test "sends Authorization header with access token" do
    stub_gcp_projects_list

    Gcp::ProjectsClient.new(ACCESS_TOKEN).list

    assert_requested :get,
                     "https://cloudresourcemanager.googleapis.com/v1/projects",
                     headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" },
                     query:   hash_including("filter" => "lifecycleState:ACTIVE")
  end

  test "filters by ACTIVE lifecycle state" do
    stub_gcp_projects_list

    Gcp::ProjectsClient.new(ACCESS_TOKEN).list

    assert_requested :get,
                     "https://cloudresourcemanager.googleapis.com/v1/projects",
                     query: hash_including("filter" => "lifecycleState:ACTIVE")
  end

  test "raises ApiError on non-200 response" do
    stub_gcp_projects_list(status: 403)

    assert_raises(Gcp::ApiError) do
      Gcp::ProjectsClient.new(ACCESS_TOKEN).list
    end
  end

  test "raises ApiError on network failure" do
    stub_request(:get, "https://cloudresourcemanager.googleapis.com/v1/projects")
      .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
      .to_raise(Faraday::ConnectionFailed.new("connection refused"))

    assert_raises(Gcp::ApiError) do
      Gcp::ProjectsClient.new(ACCESS_TOKEN).list
    end
  end

  test "handles missing projects key in response" do
    stub_request(:get, "https://cloudresourcemanager.googleapis.com/v1/projects")
      .with(query: hash_including("filter" => "lifecycleState:ACTIVE"))
      .to_return(
        status: 200,
        body:   "{}",
        headers: { "Content-Type" => "application/json" }
      )

    projects = Gcp::ProjectsClient.new(ACCESS_TOKEN).list

    assert_empty projects
  end
end
