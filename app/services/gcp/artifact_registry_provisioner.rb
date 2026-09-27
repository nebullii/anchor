module Gcp
  # Creates the Artifact Registry Docker repository used to store container images.
  # Idempotent — safe to call even if the repository already exists.
  #
  # Commands go through an injectable Providers::CommandRunner so specs can
  # assert on the exact argv without ever invoking gcloud.
  class ArtifactRegistryProvisioner
    REPOSITORY_ID = "anchor"
    FORMAT        = "DOCKER"

    def initialize(user, gcp_project_id, region, runner: Providers::CommandRunner.new)
      @user           = user
      @gcp_project_id = gcp_project_id
      @region         = region
      @runner         = runner
    end

    # Ensures the Artifact Registry repo exists.
    # Returns the repository URI (e.g. us-central1-docker.pkg.dev/my-project/anchor).
    def call(&block)
      block&.call("Ensuring Artifact Registry repository '#{REPOSITORY_ID}' exists…")

      Gcp::ShellEnv.for_user(@user) do |env|
        # Check existence first; create only if missing.
        describe = @runner.call(
          [ "gcloud", "artifacts", "repositories", "describe", REPOSITORY_ID,
            "--location=#{@region}", "--project=#{@gcp_project_id}" ],
          env: env
        )

        if describe.success?
          block&.call("Artifact Registry repository already exists — skipping.")
        else
          create = @runner.call(
            [ "gcloud", "artifacts", "repositories", "create", REPOSITORY_ID,
              "--repository-format=#{FORMAT}",
              "--location=#{@region}",
              "--project=#{@gcp_project_id}",
              "--description=Anchor container images" ],
            env: env
          )

          unless create.success?
            raise Gcp::ProvisioningError,
                  "Failed to create Artifact Registry repository:\n#{create.output.to_s.lines.last(5).join}"
          end

          block&.call("Artifact Registry repository '#{REPOSITORY_ID}' created.")
        end
      end

      "#{@region}-docker.pkg.dev/#{@gcp_project_id}/#{REPOSITORY_ID}"
    end
  end
end
