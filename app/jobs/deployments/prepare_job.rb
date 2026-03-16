module Deployments
  # Step 1 of the deployment pipeline.
  #
  # Responsibilities:
  #   - Clone the repository at the target branch
  #   - Run framework detection and persist the result
  #   - Generate a Dockerfile if the repo doesn't provide one
  #   - Hand off to BuildImageJob
  #
  class PrepareJob < BaseJob
    # Repositories larger than this are rejected before cloning.
    REPO_SIZE_LIMIT_KB = 500_000  # 500 MB

    def perform(deployment_id)
      catch(:skip) do
        with_deployment(deployment_id) do |deployment|
          guard_status!(deployment, "queued", "pending")

          project    = deployment.project
          repository = project.repository

          deployment.transition_to!("analyzing")
          deployment.append_log("Analyzing repository…")

          guard_repo_size!(deployment, repository)

          deployment.append_log("Cloning #{repository.full_name} @ #{branch(project)}...")

          repo_path = clone_repository(deployment, project, repository)

          deployment.append_log("Detecting framework...")

          detection = detect_framework(deployment, repo_path, project)
          build_deployment_plan(deployment, project, detection, repo_path)
          generate_dockerfile(deployment, repo_path, detection)

          deployment.append_log("Preparation complete. Queuing container build.")
          BuildImageJob.perform_later(deployment_id, repo_path)
        end
      end
    end

    private

    def clone_repository(deployment, project, repository)
      repo_path = tmp_path(deployment)
      FileUtils.rm_rf(repo_path)
      FileUtils.mkdir_p(File.dirname(repo_path))

      clone_url = repository.authenticated_clone_url
      run_git!(
        "clone --depth=1 --branch #{Shellwords.escape(branch(project))} " \
        "#{Shellwords.escape(clone_url)} #{Shellwords.escape(repo_path)}",
        deployment: deployment,
        redact: clone_url   # never log the token-bearing URL
      )

      sha     = capture_git!("rev-parse HEAD",       repo_path)
      message = capture_git!("log -1 --pretty=%s",   repo_path)
      author  = capture_git!("log -1 --pretty=%an",  repo_path)

      deployment.update!(
        commit_sha:     sha.strip,
        commit_message: message.strip,
        commit_author:  author.strip,
        branch:         branch(project)
      )
      deployment.append_log("Cloned at #{sha.strip.first(8)}: #{message.strip}")

      repo_path
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
          metadata:  {}
        )
      end

      detection = FrameworkDetector.new(repo_path, project).call
      deployment.append_log(
        "Detected #{detection.framework} / #{detection.runtime} on port #{detection.port}."
      )
      detection
    end

    def generate_dockerfile(deployment, repo_path, detection)
      dockerfile = File.join(repo_path, "Dockerfile")
      if File.exist?(dockerfile)
        deployment.append_log("Existing Dockerfile found — skipping generation.")
      else
        DockerfileGenerator.new(repo_path, detection).call
        deployment.append_log("Generated Dockerfile for #{detection.framework}.")
      end
    end

    def build_deployment_plan(deployment, project, detection, repo_path)
      analysis = project.analysis_result.presence || {
        "framework" => detection.framework,
        "runtime" => detection.runtime,
        "port" => detection.port,
        "has_dockerfile" => File.exist?(File.join(repo_path, "Dockerfile")),
        "detected_env_vars" => []
      }

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

    # Runs a `git <args>` command, streaming output to deployment logs.
    # Pass `redact:` to replace a secret string with "[REDACTED]" in logs.
    def run_git!(args, deployment:, redact: nil)
      cmd = "git #{args} 2>&1"
      output_lines = []

      IO.popen(cmd) do |io|
        io.each_line do |raw|
          line = raw.chomp
          line = line.gsub(redact, "[REDACTED]") if redact
          output_lines << line
        end
      end

      unless $?.success?
        raise Deployments::DeploymentError,
              "git #{args.split.first} failed (exit #{$?.exitstatus}):\n" \
              "#{output_lines.last(10).join("\n")}"
      end

      output_lines.join("\n")
    end

    def capture_git!(args, repo_path)
      out = `git -C #{Shellwords.escape(repo_path)} #{args} 2>&1`
      raise Deployments::DeploymentError, "git #{args} failed: #{out}" unless $?.success?
      out
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

    def tmp_path(deployment)
      "/tmp/cloudlaunch/#{deployment.project_id}/#{deployment.id}"
    end
  end
end
