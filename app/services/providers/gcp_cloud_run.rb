require "tempfile"

module Providers
  # Google Cloud Run provider.
  #
  #   build   — Cloud Build (`gcloud builds submit --async`), polled via build_status
  #   deploy  — `gcloud run deploy --no-traffic --tag=d<id>`: a new revision reachable
  #             only at its tagged URL, so it can be health-checked before promotion
  #   promote — `gcloud run services update-traffic --to-revisions=REV=100`
  #
  # Every gcloud invocation goes through the injected runner (see
  # Providers::CommandRunner), authenticated as the project owner via OAuth
  # token or service account key.
  class GcpCloudRun < Base
    REVISION_TAG_PREFIX = "d".freeze
    BUILD_TIMEOUT       = "30m".freeze
    BUILD_SUCCESS       = "SUCCESS".freeze
    BUILD_FAILURES      = %w[FAILURE INTERNAL_ERROR TIMEOUT CANCELLED EXPIRED].freeze

    # Output fragments that indicate a retryable failure (rate limits, server
    # errors, network trouble). Anything else is treated as permanent.
    TRANSIENT_PATTERNS = [
      /RESOURCE_EXHAUSTED/,
      /rate.?limit/i,
      /too many requests/i,
      /\b(?:429|500|502|503|504)\b/,
      /\bUNAVAILABLE\b/,
      /DEADLINE_EXCEEDED/,
      /internal (?:server )?error/i,
      /connection (?:reset|refused|aborted)/i,
      /timed out/i,
      /temporary failure in name resolution/i,
      /could not resolve host/i,
      /network is unreachable/i,
      /ssl.*(?:eof|handshake)/i
    ].freeze

    NOT_FOUND_PATTERN = /could not be found|NOT_FOUND|does not exist/i

    def name = "gcp_cloud_run"
    def log_source = "gcp"

    # Enables APIs and ensures the Artifact Registry repo exists. Idempotent;
    # skipped entirely once the project is marked provisioned.
    def provision!(log: NOOP_LOG)
      return if project.gcp_provisioned?

      ensure_connected!
      log.call("Setting up Google Cloud infrastructure (first deploy)…")

      with_credential_errors do
        Gcp::ApiEnabler.new(project.user, project.gcp_project_id, runner: runner).call(&log)
        Gcp::ArtifactRegistryProvisioner.new(
          project.user, project.gcp_project_id, project.gcp_region, runner: runner
        ).call(&log)
      end

      project.update!(gcp_provisioned: true, gcp_provisioned_at: Time.current, gcp_provision_error: nil)
      log.call("Google Cloud infrastructure ready.")
    rescue Gcp::ProvisioningError => e
      project.update_columns(gcp_provision_error: e.message)
      raise classify_failure(e.message),
            "GCP setup failed: #{e.message}\n\n" \
            "Make sure your service account has the Editor role (not Firebase Admin SDK)."
    end

    # Submits source_dir to Cloud Build asynchronously and returns the build ID.
    # Also records the target image URL on the deployment.
    def build!(deployment, source_dir, log: NOOP_LOG)
      image = image_ref(deployment)
      log.call("Submitting build to Cloud Build…")
      log.call("Image: #{image}")

      output = gcloud!(
        [ "builds", "submit", source_dir.to_s,
          "--project=#{project.gcp_project_id}",
          "--tag=#{image}",
          "--timeout=#{BUILD_TIMEOUT}",
          "--async",
          "--format=value(id)" ],
        log: log
      )

      build_id = output.lines.map(&:strip).reject(&:empty?).last
      raise Providers::Error, "Cloud Build did not return a build ID" if build_id.blank?

      deployment.update!(image_url: image, cloud_build_id: build_id)
      build_id
    end

    def build_status(deployment)
      ref = build_ref!(deployment)
      output = gcloud!(
        [ "builds", "describe", ref, "--project=#{project.gcp_project_id}", "--format=json" ]
      )
      data = parse_json(output)
      raise Providers::Error, "Could not parse Cloud Build status for #{ref}" unless data

      state   = data["status"].to_s.upcase
      log_url = data["logUrl"].presence || console_build_url(ref)

      if state == BUILD_SUCCESS
        BuildStatus.new(state: :success, detail: state, log_url: log_url)
      elsif BUILD_FAILURES.include?(state)
        detail = data.dig("failureInfo", "detail").presence || "see Cloud Build logs for details"
        BuildStatus.new(state: :failure, detail: "Cloud Build #{state.downcase}: #{detail}", log_url: log_url)
      else
        BuildStatus.new(state: :pending, detail: state.presence || "UNKNOWN", log_url: log_url)
      end
    end

    # Stops the Cloud Build so it stops consuming build minutes.
    # Returns false when there is nothing to cancel.
    def cancel_build!(deployment)
      ref = deployment.build_ref.presence || deployment.cloud_build_id.presence
      return false if ref.blank?

      gcloud!([ "builds", "cancel", ref, "--project=#{project.gcp_project_id}" ])
      true
    rescue Providers::Error => e
      # Already finished builds cannot be cancelled — that is not a failure.
      return false if e.message.match?(/FAILED_PRECONDITION|not (?:running|cancellable)|already/i)
      raise
    end

    # Deploys the built image as a new revision that receives NO traffic.
    # Cloud Run rejects --no-traffic when creating a brand-new service, so the
    # very first deploy of a service omits it (there is no traffic to protect).
    def deploy_revision!(deployment, env:, log: NOOP_LOG)
      image = deployment.image_url.presence || image_ref(deployment)
      tag   = revision_tag(deployment)
      new_service = !service_exists?

      log.call("Deploying revision #{tag} of #{project.service_name} to Cloud Run (#{project.gcp_region})…")

      with_env_vars_file(env) do |env_file|
        argv = [
          "run", "deploy", project.service_name,
          "--project=#{project.gcp_project_id}",
          "--region=#{project.gcp_region}",
          "--image=#{image}",
          "--platform=managed",
          access_flag,
          "--port=#{container_port}",
          "--memory=#{memory_setting}",
          "--cpu=1",
          "--min-instances=0",
          "--max-instances=10",
          "--tag=#{tag}"
        ]
        argv << "--no-traffic" unless new_service
        # --env-vars-file (YAML) avoids injection via commas/equals in values;
        # with no secrets we clear stale vars left from earlier deploys.
        argv << (env_file ? "--env-vars-file=#{env_file}" : "--clear-env-vars")
        argv << "--format=json"

        output = gcloud!(argv, log: log, redact: env.values.map(&:to_s))
        revision_from(output, tag)
      end
    end

    def promote!(deployment, log: NOOP_LOG)
      revision = deployment.revision_name
      raise Providers::Error, "Deployment #{deployment.id} has no revision to promote" if revision.blank?

      update_traffic!(project, revision, log: log)
    end

    def rollback!(project, revision_name, log: NOOP_LOG)
      raise Providers::Error, "No revision given to roll back to" if revision_name.blank?

      update_traffic!(project, revision_name, log: log)
    end

    # Best effort — a revision still serving traffic cannot be deleted, and
    # cleanup failures must never fail a deployment.
    def delete_revision!(deployment)
      return false if deployment.revision_name.blank?

      gcloud!(
        [ "run", "revisions", "delete", deployment.revision_name,
          "--project=#{project.gcp_project_id}",
          "--region=#{project.gcp_region}",
          "--platform=managed",
          "--quiet" ]
      )
      true
    rescue Providers::Error => e
      Rails.logger.warn("[Providers::GcpCloudRun] delete_revision! failed for #{deployment.revision_name}: #{e.message}")
      false
    end

    # Artifact Registry image for this deployment.
    def image_ref(deployment)
      "#{project.gcp_region}-docker.pkg.dev/#{project.gcp_project_id}/" \
        "#{Gcp::ArtifactRegistryProvisioner::REPOSITORY_ID}/#{project.service_name}:#{deployment.id}"
    end

    # Cloud Run traffic tag for a deployment's revision (lowercase, starts with a letter).
    def revision_tag(deployment)
      "#{REVISION_TAG_PREFIX}#{deployment.id}"
    end

    private

    # Runs `gcloud <args>` with the project owner's credentials. Returns output.
    def gcloud!(args, log: NOOP_LOG, redact: [])
      ensure_connected!
      with_gcloud_env do |env, secrets|
        run!([ "gcloud", *args ], env: env, log: log, redact: redact + secrets).output.to_s
      end
    end

    def ensure_connected!
      return if project.user.google_connected?

      raise Providers::Error,
            "Google Cloud not connected. Connect via OAuth or add a service account key in Settings."
    end

    # Yields (env, secrets_to_redact).
    def with_gcloud_env
      with_credential_errors do
        Gcp::ShellEnv.for_user(project.user) do |env|
          yield env, [ env["CLOUDSDK_AUTH_ACCESS_TOKEN"] ].compact
        end
      end
    end

    # Maps token-refresh failures (Signet / Faraday) to provider errors while
    # letting provider errors raised inside the block pass through untouched.
    def with_credential_errors
      yield
    rescue Providers::Error, Gcp::ProvisioningError
      raise
    rescue StandardError => e
      name = e.class.name.to_s
      raise unless name.start_with?("Signet::", "Faraday::")

      if name.match?(/Transmission|Connection|Timeout|Server/)
        raise Providers::TransientError, "Could not reach Google to refresh credentials: #{e.message}"
      end
      raise Providers::Error, "Google authorization failed — reconnect Google Cloud in Settings (#{e.message})"
    end

    def classify_failure(output)
      TRANSIENT_PATTERNS.any? { |p| output.to_s.match?(p) } ? Providers::TransientError : Providers::Error
    end

    def service_exists?
      ensure_connected!
      with_gcloud_env do |env, secrets|
        result = runner.call(
          [ "gcloud", "run", "services", "describe", project.service_name,
            "--project=#{project.gcp_project_id}",
            "--region=#{project.gcp_region}",
            "--platform=managed",
            "--format=value(metadata.name)" ],
          env: env, redact: secrets
        )
        next true if result.success?
        next false if result.output.to_s.match?(NOT_FOUND_PATTERN)

        raise classify_failure(result.output), "Could not look up Cloud Run service: #{result.output.to_s.lines.last(5).join.strip}"
      end
    end

    def update_traffic!(target_project, revision, log:)
      log.call("Routing 100% of traffic to #{revision}…")
      output = gcloud!(
        [ "run", "services", "update-traffic", target_project.service_name,
          "--project=#{target_project.gcp_project_id}",
          "--region=#{target_project.gcp_region}",
          "--platform=managed",
          "--to-revisions=#{revision}=100",
          "--format=json" ],
        log: log
      )

      url = parse_json(output)&.dig("status", "url").presence || output[%r{https://[\w\-]+\.run\.app}]
      url.presence || gcloud!(
        [ "run", "services", "describe", target_project.service_name,
          "--project=#{target_project.gcp_project_id}",
          "--region=#{target_project.gcp_region}",
          "--platform=managed",
          "--format=value(status.url)" ]
      ).strip.presence || raise(Providers::Error, "Could not determine Cloud Run service URL")
    end

    # Extracts the tagged revision from `gcloud run deploy --format=json`.
    def revision_from(output, tag)
      data    = parse_json(output) || {}
      traffic = Array(data.dig("status", "traffic"))
      tagged  = traffic.find { |t| t["tag"] == tag } || {}

      name = tagged["revisionName"].presence || data.dig("status", "latestCreatedRevisionName").presence
      raise Providers::Error, "Could not determine the new Cloud Run revision name from gcloud output" if name.blank?

      service_url = data.dig("status", "url").presence || output[%r{https://[\w\-]+\.run\.app}]
      url = tagged["url"].presence || (service_url && service_url.sub(%r{\Ahttps://}, "https://#{tag}---"))
      raise Providers::Error, "Could not determine the tagged revision URL from gcloud output" if url.blank?

      Revision.new(name: name, url: url)
    end

    def with_env_vars_file(env)
      return yield(nil) if env.blank?

      file = Tempfile.new([ "cr-env-#{project.id}-", ".yaml" ])
      file.write(env.to_h.transform_keys(&:to_s).transform_values(&:to_s).to_yaml)
      file.flush
      yield file.path
    ensure
      file&.close
      file&.unlink
    end

    def access_flag
      project.try(:public_access) == false ? "--no-allow-unauthenticated" : "--allow-unauthenticated"
    end

    def build_ref!(deployment)
      ref = deployment.build_ref.presence || deployment.cloud_build_id.presence
      raise Providers::Error, "Deployment #{deployment.id} has no build reference" if ref.blank?
      ref
    end

    def parse_json(output)
      start = output.to_s.index("{")
      return nil unless start
      JSON.parse(output[start..])
    rescue JSON::ParserError
      nil
    end

    def console_build_url(build_id)
      "https://console.cloud.google.com/cloud-build/builds/#{build_id}?project=#{project.gcp_project_id}"
    end
  end
end
