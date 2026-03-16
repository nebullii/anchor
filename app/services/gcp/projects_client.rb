module Gcp
  # Lists GCP projects accessible to the authenticated user via the
  # Cloud Resource Manager API.
  #
  # Returns an array of hashes: [{ id:, name:, number: }, ...]
  # Raises Gcp::ApiError on HTTP or parse failures.
  #
  class ProjectsClient
    API_URL = "https://cloudresourcemanager.googleapis.com/v1/projects".freeze
    TIMEOUT = 15

    def initialize(access_token)
      @access_token = access_token
    end

    def list
      response = connection.get(API_URL) do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}"
        req.params["filter"]         = "lifecycleState:ACTIVE"
      end

      raise Gcp::ApiError, "Failed to list projects (HTTP #{response.status})" unless response.success?

      data = response.body
      projects = data["projects"] || []
      projects.map do |p|
        {
          id:     p["projectId"],
          name:   p["name"],
          number: p["projectNumber"]
        }
      end
    rescue Faraday::Error => e
      raise Gcp::ApiError, "Network error listing GCP projects: #{e.message}"
    end

    private

    def connection
      Faraday.new do |f|
        f.options.timeout      = TIMEOUT
        f.options.open_timeout = 10
        f.response :json
      end
    end
  end
end
