module Gcp
  # Creates the Artifact Registry Docker repository used to store container images.
  # Idempotent — safe to call even if the repository already exists.
  class ArtifactRegistryProvisioner
    REPOSITORY_ID = "anchor"
    FORMAT        = "DOCKER"

    def initialize(user, gcp_project_id, region)
      @user           = user
      @gcp_project_id = gcp_project_id
      @region         = region
    end

    # Ensures the Artifact Registry repo exists.
    # Returns the repository URI (e.g. us-central1-docker.pkg.dev/my-project/anchor).
    def call
      yield "Ensuring Artifact Registry repository '#{REPOSITORY_ID}' exists…" if block_given?

      with_gcp_env do |env|
        # Check existence first; create only if missing.
        describe_cmd = "gcloud artifacts repositories describe #{REPOSITORY_ID} " \
                       "--location=#{Shellwords.escape(@region)} " \
                       "--project=#{Shellwords.escape(@gcp_project_id)} 2>&1"

        IO.popen(env, describe_cmd, &:read)

        if $?.success?
          yield "Artifact Registry repository already exists — skipping." if block_given?
        else
          create_cmd = "gcloud artifacts repositories create #{REPOSITORY_ID} " \
                       "--repository-format=#{FORMAT} " \
                       "--location=#{Shellwords.escape(@region)} " \
                       "--project=#{Shellwords.escape(@gcp_project_id)} " \
                       "--description='Anchor container images' 2>&1"

          output = ""
          IO.popen(env, create_cmd) do |io|
            output = io.read
          end

          unless $?.success?
            raise Gcp::ProvisioningError,
                  "Failed to create Artifact Registry repository:\n#{output.lines.last(5).join}"
          end

          yield "Artifact Registry repository '#{REPOSITORY_ID}' created." if block_given?
        end
      end

      "#{@region}-docker.pkg.dev/#{@gcp_project_id}/#{REPOSITORY_ID}"
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
