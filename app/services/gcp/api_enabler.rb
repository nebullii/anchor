module Gcp
  # Enables the GCP APIs required by Anchor before the first deployment.
  # Uses `gcloud services enable` which is idempotent — safe to call repeatedly.
  class ApiEnabler
    REQUIRED_APIS = %w[
      cloudbuild.googleapis.com
      run.googleapis.com
      artifactregistry.googleapis.com
      secretmanager.googleapis.com
      storage.googleapis.com
      iam.googleapis.com
      cloudresourcemanager.googleapis.com
    ].freeze

    def initialize(user, gcp_project_id)
      @user           = user
      @gcp_project_id = gcp_project_id
    end

    # Enables all required APIs. Yields log lines if a block is given.
    # Returns the list of APIs that were enabled.
    def call
      yield "Enabling required GCP APIs for #{@gcp_project_id}…" if block_given?

      @user.with_gcp_credentials_file do |key_path|
        env = {
          "GOOGLE_APPLICATION_CREDENTIALS"         => key_path,
          "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" => key_path,
          "CLOUDSDK_CORE_DISABLE_PROMPTS"          => "1"
        }

        apis_joined = REQUIRED_APIS.join(" ")
        cmd = "gcloud services enable #{apis_joined} --project=#{Shellwords.escape(@gcp_project_id)} 2>&1"

        output_lines = []
        IO.popen(env, cmd) do |io|
          io.each_line do |raw|
            line = raw.chomp
            output_lines << line
            yield line if block_given? && line.present?
          end
        end

        unless $?.success?
          raise Gcp::ProvisioningError,
                "Failed to enable GCP APIs:\n#{output_lines.last(5).join("\n")}"
        end
      end

      REQUIRED_APIS
    end
  end
end
