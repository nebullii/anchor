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

      with_gcp_env do |env|
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

    private

    def with_gcp_env
      if @user.google_oauth_connected?
        yield Gcp::ShellEnv.with_token(@user.fresh_google_token!)
      else
        @user.with_gcp_credentials_file do |key_path|
          yield Gcp::ShellEnv.with_key(key_path)
        end
      end
    end
  end
end
