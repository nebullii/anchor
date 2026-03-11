module Gcp
  # Creates a dedicated Anchor service account in the user's GCP project,
  # grants it the minimum required IAM roles, and generates a JSON key.
  #
  # Usage:
  #   result = Gcp::ServiceAccountCreator.new(project_id, access_token).call
  #   result[:email]    # => "anchor-deploy-abc1@project.iam.gserviceaccount.com"
  #   result[:key_json] # => '{"type":"service_account",...}'
  #
  # Raises Gcp::ApiError on any failure.
  #
  class ServiceAccountCreator
    ACCOUNT_ID = "anchor-deploy".freeze
    DISPLAY_NAME = "Anchor Deploy".freeze

    REQUIRED_ROLES = %w[
      roles/cloudbuild.builds.editor
      roles/run.admin
      roles/artifactregistry.writer
      roles/storage.admin
      roles/iam.serviceAccountUser
    ].freeze

    IAM_BASE    = "https://iam.googleapis.com/v1".freeze
    CRM_BASE    = "https://cloudresourcemanager.googleapis.com/v1".freeze
    TIMEOUT     = 20

    def initialize(project_id, access_token)
      @project_id   = project_id
      @access_token = access_token
    end

    def call
      email = find_or_create_service_account
      bind_iam_roles(email)
      key_json = create_key(email)
      { email: email, key_json: key_json }
    end

    private

    def find_or_create_service_account
      email = "#{ACCOUNT_ID}@#{@project_id}.iam.gserviceaccount.com"

      # Check if it already exists
      response = authed_get("#{IAM_BASE}/projects/#{@project_id}/serviceAccounts/#{email}")
      return email if response.success?

      # Create it
      response = authed_post(
        "#{IAM_BASE}/projects/#{@project_id}/serviceAccounts",
        accountId:      ACCOUNT_ID,
        serviceAccount: { displayName: DISPLAY_NAME }
      )

      unless response.success?
        raise Gcp::ApiError,
              "Failed to create service account (HTTP #{response.status}): #{response.body}"
      end

      response.body["email"]
    end

    def bind_iam_roles(service_account_email)
      member = "serviceAccount:#{service_account_email}"

      # Fetch current policy
      policy_response = authed_post(
        "#{CRM_BASE}/projects/#{@project_id}:getIamPolicy", {}
      )

      unless policy_response.success?
        raise Gcp::ApiError,
              "Failed to get IAM policy (HTTP #{policy_response.status}): #{policy_response.body}"
      end

      policy = policy_response.body
      bindings = policy["bindings"] || []

      REQUIRED_ROLES.each do |role|
        binding = bindings.find { |b| b["role"] == role }
        if binding
          binding["members"] |= [member]
        else
          bindings << { "role" => role, "members" => [member] }
        end
      end

      policy["bindings"] = bindings

      set_response = authed_post(
        "#{CRM_BASE}/projects/#{@project_id}:setIamPolicy",
        policy: policy
      )

      unless set_response.success?
        raise Gcp::ApiError,
              "Failed to set IAM policy (HTTP #{set_response.status}): #{set_response.body}"
      end
    end

    def create_key(service_account_email)
      response = authed_post(
        "#{IAM_BASE}/projects/#{@project_id}/serviceAccounts/#{service_account_email}/keys",
        {}
      )

      unless response.success?
        raise Gcp::ApiError,
              "Failed to create service account key (HTTP #{response.status}): #{response.body}"
      end

      # Key is base64-encoded JSON
      Base64.decode64(response.body["privateKeyData"])
    end

    def authed_get(url)
      connection.get(url) do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}"
      end
    end

    def authed_post(url, body)
      connection.post(url) do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}"
        req.headers["Content-Type"]  = "application/json"
        req.body = body.to_json
      end
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.options.timeout      = TIMEOUT
        f.options.open_timeout = 10
        f.response :json
      end
    end
  end
end
