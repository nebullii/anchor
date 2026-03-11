module Deployments
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

          deployment.append_log("Deployment complete.")
          deployment.append_log("Live at: #{service_url}")
          deployment.transition_to!("success")
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
  end
end
