module Deployments
  # Step 2 of the deployment pipeline.
  #
  # Submits the cloned repository to Google Cloud Build using the gcloud CLI.
  # Cloud Build uploads the source to GCS, builds the Docker image, and pushes
  # it to Artifact Registry.
  #
  # On success, saves the image URL and Cloud Build ID, then hands off to
  # PollBuildStatusJob which waits for the build to finish asynchronously.
  #
  class BuildImageJob < BaseJob
    def perform(deployment_id, repo_path)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "cloning", "detecting")

          deployment.transition_to!("building")

          project   = deployment.project
          image_url = full_image_url(deployment)

          deployment.append_log("Submitting build to Cloud Build...")
          deployment.append_log("Image: #{image_url}")

          build_id = submit_build(deployment, repo_path, image_url, project)

          deployment.update!(
            image_url:     image_url,
            cloud_build_id: build_id
          )
          deployment.append_log("Build submitted (build_id=#{build_id}).")
          deployment.append_log("Waiting for Cloud Build to finish...")

          PollBuildStatusJob.perform_later(deployment_id, build_id, attempt: 1)
        end
      end
    ensure
      # Repo is no longer needed once the source is uploaded to GCS.
      cleanup_repo(repo_path)
    end

    private

    def submit_build(deployment, repo_path, image_url, project)
      # --no-source is not used here — gcloud builds submit handles the GCS upload
      # automatically when given a local directory.
      cmd = [
        "gcloud builds submit",
        "--project=#{Shellwords.escape(project.gcp_project_id)}",
        "--tag=#{Shellwords.escape(image_url)}",
        "--timeout=30m",
        "--async",           # return immediately with a build ID; poll separately
        "--format=value(id)",
        Shellwords.escape(repo_path)
      ].join(" ")

      output = run_gcloud!(cmd, deployment: deployment, source: "cloud_build")
      build_id = output.lines.map(&:strip).reject(&:empty?).last

      raise Deployments::DeploymentError, "Cloud Build did not return a build ID" if build_id.blank?
      build_id
    end

    def full_image_url(deployment)
      project = deployment.project
      "#{project.gcp_region}-docker.pkg.dev" \
      "/#{project.gcp_project_id}/cloudlaunch" \
      "/#{project.service_name}:#{deployment.id}"
    end

    def cleanup_repo(repo_path)
      return unless repo_path && Dir.exist?(repo_path.to_s)
      FileUtils.rm_rf(repo_path)
    rescue => e
      Rails.logger.warn("[BuildImageJob] Cleanup failed for #{repo_path}: #{e.message}")
    end
  end
end
