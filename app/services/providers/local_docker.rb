require "socket"

module Providers
  # Free, no-cloud provider: builds and runs apps with the local Docker daemon
  # so Anchor can be exercised end-to-end on a laptop.
  #
  #   build   — synchronous `docker build`; build_status just checks the image exists
  #   deploy  — `docker run -d` on a free localhost port; each deployment gets its
  #             own container `anchor-<service>-<deployment_id>` (the "revision")
  #   promote — starts the new container and stops the project's other containers
  #             (they are kept, not removed, so rollback can restart them)
  #
  # Assumes the Anchor worker and the Docker daemon share a host, which is the
  # point of this provider. Containers bind to 127.0.0.1 only.
  class LocalDocker < Base
    IMAGE_PREFIX  = "anchor-local".freeze
    LABEL_PROJECT = "anchor.project".freeze
    LABEL_DEPLOY  = "anchor.deployment".freeze
    LABEL_SERVICE = "anchor.service".freeze

    def initialize(project, runner: CommandRunner.new, port_allocator: nil)
      super(project, runner: runner)
      @port_allocator = port_allocator || method(:free_port)
    end

    def name = "local_docker"

    # Verifies the Docker daemon is reachable. Nothing to create.
    def provision!(log: NOOP_LOG)
      result = runner.call(%w[docker version --format {{.Server.Version}}])
      unless result.success?
        raise Providers::Error,
              "Docker daemon is not reachable — start Docker Desktop (or dockerd) and retry.\n" \
              "#{result.output.to_s.lines.last(3).join.strip}"
      end
      log.call("Using local Docker #{result.output.to_s.strip} (no cloud account needed).")
    end

    # Builds synchronously. The PID of the docker CLI is recorded so that
    # cancel_build! (possibly from another process) can interrupt it.
    def build!(deployment, source_dir, log: NOOP_LOG)
      image = image_ref(deployment)
      log.call("Building #{image} with local Docker…")

      run!(
        [ "docker", "build",
          "--label", "#{LABEL_PROJECT}=#{project.id}",
          "--label", "#{LABEL_DEPLOY}=#{deployment.id}",
          "-t", image,
          source_dir.to_s ],
        log: log,
        on_spawn: ->(pid) { write_pid(deployment, pid) }
      )

      deployment.update!(image_url: image)
      log.call("Built #{image}.")
      image
    ensure
      clear_pid(deployment)
    end

    # Builds are synchronous, so the result is already known: the image
    # either exists (success) or it does not (failure).
    def build_status(deployment)
      ref = deployment.build_ref.presence || deployment.image_url.presence
      return BuildStatus.new(state: :failure, detail: "No local build recorded") if ref.blank?

      result = runner.call([ "docker", "image", "inspect", "--format", "{{.Id}}", ref ])
      if result.success?
        BuildStatus.new(state: :success, detail: result.output.to_s.strip)
      else
        BuildStatus.new(state: :failure, detail: "Local image #{ref} not found")
      end
    end

    # Interrupts an in-flight `docker build` (BuildKit aborts when its client dies).
    def cancel_build!(deployment)
      pid = read_pid(deployment)
      return false unless pid

      Process.kill("TERM", pid)
      true
    rescue Errno::ESRCH
      false
    ensure
      clear_pid(deployment)
    end

    # Starts the image in a fresh container on a free localhost port.
    # Secrets are passed as `-e KEY` (value read from the docker CLI's env)
    # so they never appear on a command line or in a file.
    def deploy_revision!(deployment, env:, log: NOOP_LOG)
      container = container_name(deployment)
      image     = deployment.image_url.presence || image_ref(deployment)
      host_port = @port_allocator.call
      env       = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)

      # Idempotent on retry: drop any half-started container with this name.
      runner.call([ "docker", "rm", "-f", container ])

      argv = [
        "docker", "run", "-d",
        "--name", container,
        "--label", "#{LABEL_PROJECT}=#{project.id}",
        "--label", "#{LABEL_DEPLOY}=#{deployment.id}",
        "--label", "#{LABEL_SERVICE}=#{project.service_name}",
        "-p", "127.0.0.1:#{host_port}:#{container_port}",
        "--memory", docker_memory,
        "--restart", "unless-stopped",
        "-e", "PORT=#{container_port}"
      ]
      env.each_key { |key| argv.push("-e", key) }
      argv << image

      log.call("Starting container #{container} on http://localhost:#{host_port}…")
      run!(argv, env: env, log: log, redact: env.values)

      Revision.new(name: container, url: "http://localhost:#{host_port}")
    end

    # "Shifts traffic" by making this container the only running one for the project.
    def promote!(deployment, log: NOOP_LOG)
      container = deployment.revision_name
      raise Providers::Error, "Deployment #{deployment.id} has no container to promote" if container.blank?

      activate!(project, container, log: log)
      deployment.revision_url.presence || url_for(container)
    end

    def rollback!(project, revision_name, log: NOOP_LOG)
      raise Providers::Error, "No container given to roll back to" if revision_name.blank?

      activate!(project, revision_name, log: log)
      url_for(revision_name)
    end

    def delete_revision!(deployment)
      return false if deployment.revision_name.blank?
      runner.call([ "docker", "rm", "-f", deployment.revision_name ]).success?
    end

    def image_ref(deployment)
      "#{IMAGE_PREFIX}/#{project.service_name}:#{deployment.id}"
    end

    def container_name(deployment)
      "anchor-#{project.service_name}-#{deployment.id}"
    end

    # URL the health check should probe. The revision URL points at localhost,
    # which is wrong when the worker itself runs in a container (docker compose):
    # set ANCHOR_LOCAL_DOCKER_HOST=host.docker.internal there.
    def health_check_url(deployment)
      host = ENV["ANCHOR_LOCAL_DOCKER_HOST"].presence
      url  = deployment.revision_url.to_s
      host ? url.sub("//localhost:", "//#{host}:") : url
    end

    private

    # Starts `container` and stops every other container labelled for the project.
    def activate!(target_project, container, log:)
      start = runner.call([ "docker", "start", container ])
      unless start.success?
        raise Providers::Error,
              "Could not start container #{container} — it may have been removed; redeploy instead.\n" \
              "#{start.output.to_s.lines.last(3).join.strip}"
      end

      others = run!(
        [ "docker", "ps", "--filter", "label=#{LABEL_PROJECT}=#{target_project.id}", "--format", "{{.Names}}" ]
      ).output.to_s.lines.map(&:strip).reject { |n| n.empty? || n == container }

      others.each do |other|
        log.call("Stopping previous container #{other}…")
        runner.call([ "docker", "stop", other ])
      end
      log.call("#{container} is now live.")
    end

    # Resolves the host port docker bound for the container.
    def url_for(container)
      output = run!([ "docker", "port", container ]).output.to_s
      port   = output.lines.map { |l| l[/:(\d+)\s*\z/, 1] }.compact.first
      raise Providers::Error, "Container #{container} has no published port" unless port
      "http://localhost:#{port}"
    end

    # "512Mi" -> "512m", "1Gi" -> "1g"; anything else is passed through.
    def docker_memory
      memory_setting.to_s.sub(/\A(\d+)([MG])i\z/i) { "#{$1}#{$2.downcase}" }
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def pid_path(deployment)
      Rails.root.join("tmp", "anchor_builds", "#{deployment.id}.pid")
    end

    def write_pid(deployment, pid)
      path = pid_path(deployment)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, pid.to_s)
    end

    def read_pid(deployment)
      path = pid_path(deployment)
      return nil unless File.exist?(path)
      pid = File.read(path).to_i
      pid.positive? ? pid : nil
    end

    def clear_pid(deployment)
      FileUtils.rm_f(pid_path(deployment))
    end
  end
end
