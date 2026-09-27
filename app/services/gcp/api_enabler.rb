module Gcp
  # Enables the GCP APIs required by Anchor before the first deployment.
  # Uses `gcloud services enable` which is idempotent — safe to call repeatedly.
  #
  # Commands go through an injectable Providers::CommandRunner so specs can
  # assert on the exact argv without ever invoking gcloud.
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

    def initialize(user, gcp_project_id, runner: Providers::CommandRunner.new)
      @user           = user
      @gcp_project_id = gcp_project_id
      @runner         = runner
    end

    # Enables all required APIs. Yields log lines if a block is given.
    # Returns the list of APIs that were enabled.
    def call(&block)
      block&.call("Enabling required GCP APIs for #{@gcp_project_id}…")

      Gcp::ShellEnv.for_user(@user) do |env|
        argv = [ "gcloud", "services", "enable", *REQUIRED_APIS, "--project=#{@gcp_project_id}" ]
        result = @runner.call(argv, env: env, log: block)

        unless result.success?
          raise Gcp::ProvisioningError,
                "Failed to enable GCP APIs:\n#{result.output.to_s.lines.last(5).join}"
        end
      end

      REQUIRED_APIS
    end
  end
end
