module Deployments
  require "net/http"
  require "uri"

  # Step 4 (final) of the deployment pipeline.
  #
  # Deploys the built container image to Google Cloud Run using the gcloud CLI.
  # Injects environment variables from the project's Secrets, sets resource limits,
  # and persists the live service URL on success.
  #
  class DeployToCloudRunJob < BaseJob
    def perform(deployment_id)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "building")

          deployment.transition_to!("deploying")

          project = deployment.project
          deployment.append_log("Deploying #{project.service_name} to Cloud Run (#{project.gcp_region})...")

          service_url = run_deploy(deployment, project)

          deployment.update!(service_url: service_url)
          project.update!(latest_url: service_url)

          deployment.transition_to!("health_check")
          run_health_check!(deployment, service_url)

          deployment.append_log("Deployment complete.")
          deployment.append_log("Live at: #{service_url}")
          deployment.transition_to!("running")
        end
      end
    end

    private

    def run_deploy(deployment, project)
      env_file = write_env_vars_file(project)
      cmd      = build_command(deployment, project, env_file&.path)
      output   = run_gcloud!(cmd, deployment: deployment, source: "cloud_run")
      extract_url(output, project)
    ensure
      env_file&.close
      env_file&.unlink
    end

    # Writes env vars as a YAML file safe for --env-vars-file.
    # Returns nil if there are no secrets.
    def write_env_vars_file(project)
      env_hash = Secret.to_env_hash(project)
      return nil if env_hash.empty?

      file = Tempfile.new([ "cr-env-#{project.id}-", ".yaml" ])
      yaml = env_hash.transform_values(&:to_s).to_yaml
      file.write(yaml)
      file.flush
      file
    end

    def build_command(deployment, project, env_vars_file_path)
      parts = [
        "gcloud run deploy #{Shellwords.escape(project.service_name)}",
        "--project=#{Shellwords.escape(project.gcp_project_id)}",
        "--region=#{Shellwords.escape(project.gcp_region)}",
        "--image=#{Shellwords.escape(deployment.image_url)}",
        "--platform=managed",
        "--allow-unauthenticated",
        "--port=#{container_port(project)}",
        "--memory=512Mi",
        "--cpu=1",
        "--min-instances=0",
        "--max-instances=10",
        "--format=json"
      ]

      # Use --env-vars-file (YAML key: value) to avoid injection via commas/equals in values.
      parts << "--env-vars-file=#{Shellwords.escape(env_vars_file_path)}" if env_vars_file_path

      parts.join(" \\\n  ")
    end

    def extract_url(output, project)
      # gcloud --format=json returns the full Service resource; parse status.url first.
      json_start = output.index("{")
      if json_start
        data = JSON.parse(output[json_start..])
        url  = data.dig("status", "url")
        return url if url.present?
      end

      # Fallback: scrape *.run.app URL from plain-text output.
      match = output.match(%r{https://[\w\-]+\.run\.app})
      return match[0] if match

      raise Deployments::DeploymentError,
            "Could not extract Cloud Run service URL from gcloud output.\n" \
            "Check the Cloud Console for project #{project.gcp_project_id}."
    rescue JSON::ParserError
      match = output.match(%r{https://[\w\-]+\.run\.app})
      raise Deployments::DeploymentError, "Could not extract service URL" unless match
      match[0]
    end

    def container_port(project)
      project.port || 3000
    end

    # Cloud Run cold starts can take 30-60s for Rails/Django apps.
    # Retry with backoff to avoid failing a successful deployment.
    HEALTH_CHECK_ATTEMPTS = 4
    HEALTH_CHECK_DELAYS   = [0, 10, 20, 30].freeze  # seconds before each attempt

    def run_health_check!(deployment, service_url)
      deployment.append_log("Running health check…")

      uri = URI.parse(service_url)
      last_error = nil

      HEALTH_CHECK_ATTEMPTS.times do |attempt|
        delay = HEALTH_CHECK_DELAYS[attempt] || 30
        if delay > 0
          deployment.append_log("Waiting #{delay}s for cold start (attempt #{attempt + 1}/#{HEALTH_CHECK_ATTEMPTS})…")
          sleep(delay)
        end

        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 15
          http.read_timeout = 30
          response = http.get(uri.path.presence || "/")

          if response.code.to_i < 500
            deployment.append_log("Health check passed (HTTP #{response.code}).")
            return
          end

          last_error = "HTTP #{response.code}"
          deployment.append_log("Health check returned #{response.code}, retrying…", level: "warn")
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
          last_error = e.message
          deployment.append_log("Health check attempt #{attempt + 1} failed: #{e.class}", level: "warn")
        end
      end

      # All attempts failed — log warning but don't fail the deployment.
      # The service is already live on Cloud Run; health check flakiness
      # shouldn't mark a successful deploy as failed.
      deployment.append_log(
        "Health check did not pass after #{HEALTH_CHECK_ATTEMPTS} attempts (#{last_error}). " \
        "The service may still be starting — check #{service_url} manually.",
        level: "warn"
      )
    end
  end
end
