require "open3"
require "tmpdir"

module Deployments
  # Step 1 of the deployment pipeline.
  #
  # Responsibilities (all inside ONE job so no local path crosses job
  # boundaries — any worker can pick up the next step):
  #   - Make sure the provider is provisioned (APIs, registry, docker daemon)
  #   - Clone the repository at the target branch into a private tmp dir
  #   - Run framework detection and persist the result
  #   - Generate a Dockerfile if the repo doesn't provide one
  #   - Hand the source to the provider's build! and record the build_ref
  #   - Enqueue PollBuildStatusJob, which only needs the deployment ID
  #
  # The tmp dir is ALWAYS removed in `ensure`, whatever happens.
  #
  class PrepareJob < BaseJob
    # Repositories larger than this are rejected before cloning.
    REPO_SIZE_LIMIT_KB = 500_000  # 500 MB

    def perform(deployment_id)
      work_dir = nil

      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          # "analyzing"/"building" are accepted so a retry after a transient
          # error resumes the step; a build that already started is not redone.
          guard_status!(deployment, "queued", "pending", "analyzing", "building")
          throw :skip if deployment.status == "building" && deployment.build_ref.present?

          project    = deployment.project
          repository = project.repository
          provider   = Providers.for(project)
          log        = ->(line) { deployment.append_log(line, source: provider.log_source) }

          deployment.transition_to!("analyzing") if %w[queued pending].include?(deployment.status)
          deployment.append_log("Analyzing repository…")

          guard_repo_size!(deployment, repository)

          # Ensure provider infrastructure is ready before trying to build.
          # Idempotent — handles first deploys and previously failed provisioning.
          Providers.translate_errors { provider.provision!(log: log) }

          deployment.append_log("Cloning #{repository.full_name} @ #{branch(project)}...")

          work_dir  = Dir.mktmpdir("anchor-deploy-#{deployment.id}-")
          repo_path = File.join(work_dir, "repo")
          clone_repository(deployment, project, repository, repo_path)

          deployment.append_log("Detecting framework...")

          detection = detect_framework(deployment, repo_path, project)
          run_preflight!(deployment, project, repo_path, detection)
          build_deployment_plan(deployment, project, detection, repo_path)
          context_dir = generate_dockerfile(deployment, repo_path, detection)

          deployment.append_log("Preparation complete. Building container image.")
          deployment.transition_to!("building")

          build_ref = Providers.translate_errors { provider.build!(deployment, context_dir, log: log) }
          deployment.update!(build_ref: build_ref)
          deployment.append_log("Build started (ref=#{build_ref}).")

          PollBuildStatusJob.perform_later(deployment.id, attempt: 1)
        end
      end
    ensure
      cleanup_work_dir(work_dir)
    end

    private

    # Shallow-clones the target branch into repo_path. If the branch does not
    # exist, falls back to the remote's actual default branch.
    def clone_repository(deployment, project, repository, repo_path)
      clone_url     = repository.authenticated_clone_url
      target_branch = branch(project)

      begin
        run_git!([ "clone", "--depth=1", "--branch", target_branch, clone_url, repo_path ],
                 redact: clone_url)
      rescue Deployments::DeploymentError => e
        # Branch doesn't exist — detect actual default and retry
        raise unless e.message.include?("not found")

        FileUtils.rm_rf(repo_path)
        actual = detect_default_branch(clone_url)
        raise unless actual && actual != target_branch

        deployment.append_log("Branch '#{target_branch}' not found — using '#{actual}' instead.")
        project.update_columns(production_branch: actual)
        repository.update_columns(default_branch: actual)
        target_branch = actual
        run_git!([ "clone", "--depth=1", "--branch", actual, clone_url, repo_path ],
                 redact: clone_url)
      end

      sha     = capture_git!(%w[rev-parse HEAD],      repo_path)
      message = capture_git!(%w[log -1 --pretty=%s],  repo_path)
      author  = capture_git!(%w[log -1 --pretty=%an], repo_path)

      deployment.update!(
        commit_sha:     sha.strip,
        commit_message: message.strip,
        commit_author:  author.strip,
        branch:         target_branch
      )
      deployment.append_log("Cloned at #{sha.strip.first(8)}: #{message.strip}")

      # .git/config holds the tokened remote URL. Drop the whole directory so the
      # token can never end up in the build context or the image.
      FileUtils.rm_rf(File.join(repo_path, ".git"))

      repo_path
    end

    # Asks the remote for its HEAD branch. The clone URL embeds the user's
    # GitHub token, so it is passed as an argv element (no shell) and any
    # output that reaches the logs is redacted first.
    def detect_default_branch(clone_url)
      out, status = Open3.capture2e("git", "ls-remote", "--symref", clone_url, "HEAD")
      unless status.success?
        Rails.logger.warn("[PrepareJob] git ls-remote failed: #{redact(out, clone_url).lines.last(3).join.strip}")
        return nil
      end
      out.match(%r{ref: refs/heads/(\S+)\s+HEAD})&.captures&.first
    rescue => e
      Rails.logger.warn("[PrepareJob] default branch detection failed: #{redact(e.message, clone_url)}")
      nil
    end

    def detect_framework(deployment, repo_path, project)
      if project.analysis_fresh?
        cached = project.analysis_result
        project.update_columns(
          framework: cached["framework"],
          runtime:   cached["runtime"],
          port:      cached["port"]
        )
        deployment.append_log(
          "Using cached analysis: #{cached['framework']} / #{cached['runtime']} on port #{cached['port']}."
        )
        return FrameworkDetector::Result.new(
          framework: cached["framework"],
          runtime:   cached["runtime"],
          port:      cached["port"],
          metadata:  cached["metadata"] || {},
          root_dir:  cached["root_dir"]
        )
      end

      detection = FrameworkDetector.new(repo_path, project).call
      deployment.append_log(
        "Detected #{detection.framework} / #{detection.runtime} on port #{detection.port}."
      )
      detection
    end

    # Writes a Dockerfile unless the app brings its own, and returns the Docker
    # build context: the app's directory (the repo root, or root_dir in a monorepo).
    def generate_dockerfile(deployment, repo_path, detection)
      generator = DockerfileGenerator.new(repo_path, detection)
      existed   = detection.respond_to?(:app_path) && File.exist?(File.join(detection.app_path(repo_path), "Dockerfile"))
      path      = generator.call
      if existed
        deployment.append_log("Existing Dockerfile found — skipping generation.")
      else
        deployment.append_log("Generated Dockerfile for #{detection.framework}.")
      end
      File.dirname(path)
    end

    # Static checks on the fresh checkout. Errors stop the deploy here, before
    # a (possibly paid) cloud build runs; warnings are logged and deploy continues.
    def run_preflight!(deployment, project, repo_path, detection)
      findings = Analysis::Preflight.new(
        repo_path, detection, project: project, secret_keys: project.secrets.pluck(:key)
      ).call
      findings.each do |f|
        next if f[:severity] == "info"
        where = [ f[:file], f[:line] ].compact.join(":")
        deployment.append_log("Preflight #{f[:severity]} [#{f[:id]}] #{f[:message]}#{" (#{where})" if where.present?}",
                              level: f[:severity] == "error" ? "error" : "warn")
      end

      errors = findings.select { |f| f[:severity] == "error" }
      return if errors.empty?

      raise Deployments::DeploymentError,
            "Preflight found #{errors.size} blocking issue(s):\n" +
            errors.map { |f| "- #{f[:message]} Fix: #{f[:fix]}" }.join("\n")
    end

    def build_deployment_plan(deployment, project, detection, repo_path)
      analysis = project.analysis_result.presence || {
        "framework" => detection.framework,
        "runtime" => detection.runtime,
        "port" => detection.port,
        "detected_env_vars" => []
      }
      # The cached analysis may predate this commit: trust the checkout.
      app_dir  = detection.respond_to?(:app_path) ? detection.app_path(repo_path) : repo_path
      analysis = analysis.merge("has_dockerfile" => File.exist?(File.join(app_dir, "Dockerfile")))

      plan = Deployments::PlanBuilder.new(
        project: project,
        analysis_result: analysis,
        user: project.user
      ).call

      deployment.update!(deployment_plan: plan)
      deployment.append_log("Deployment plan ready (readiness #{plan['deployment_readiness']}%).")
    end

    # ------------------------------------------------------------------ #
    # Shell helpers                                                        #
    # ------------------------------------------------------------------ #

    # Runs `git <argv>` (no shell), capturing output for error messages.
    # Pass `redact:` to scrub a secret (the tokened clone URL) from that output.
    def run_git!(argv, redact: nil)
      out, status = Open3.capture2e("git", *argv)
      output = redact(out, redact)

      unless status.success?
        raise Deployments::DeploymentError,
              "git #{argv.first} failed (exit #{status.exitstatus}):\n" \
              "#{output.lines.last(10).join.strip}"
      end

      output
    end

    def capture_git!(argv, repo_path)
      out, status = Open3.capture2e("git", "-C", repo_path, *argv)
      raise Deployments::DeploymentError, "git #{argv.join(' ')} failed: #{out}" unless status.success?
      out
    end

    # Removes secrets from text before it is logged or stored. Uses AppSec's
    # Security::Redactor when available (it also catches tokens in URLs and
    # bearer tokens); otherwise falls back to literal replacement plus a
    # userinfo scrub for any other credentialed URL.
    def redact(text, secret)
      text = text.to_s
      return text if secret.blank?

      if defined?(Security::Redactor)
        Security::Redactor.redact(text, secrets: [ secret ])
      else
        text.gsub(secret, "[REDACTED]").gsub(%r{(https?://)[^/\s:@]+:[^/\s@]+@}, '\1[REDACTED]@')
      end
    end

    def cleanup_work_dir(work_dir)
      return unless work_dir && Dir.exist?(work_dir)
      FileUtils.rm_rf(work_dir)
    rescue => e
      Rails.logger.warn("[PrepareJob] Cleanup failed for #{work_dir}: #{e.message}")
    end

    def guard_repo_size!(deployment, repository)
      size_kb = repository.size_kb.to_i
      return if size_kb.zero?  # size unknown — allow through
      return if size_kb <= REPO_SIZE_LIMIT_KB

      raise Deployments::DeploymentError,
            "Repository is too large to deploy (#{(size_kb / 1024.0).round(1)} MB). " \
            "Maximum allowed size is #{REPO_SIZE_LIMIT_KB / 1024} MB."
    end

    def branch(project)
      project.production_branch.presence || project.repository.default_branch
    end
  end
end
