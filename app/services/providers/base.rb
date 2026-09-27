module Providers
  # Contract every deployment provider implements. The pipeline only talks to
  # this interface, so adding a provider (Fly, ECS, Kubernetes…) means adding
  # a subclass and a REGISTRY entry — no job changes.
  #
  # All `log:` arguments are callables `->(line) {}` used to stream output to
  # the deployment log. Implementations raise Providers::Error for permanent
  # failures and Providers::TransientError for retryable ones.
  #
  # Lifecycle of one deployment:
  #   provision!       — idempotent one-time setup (APIs, registries, daemon check)
  #   build!           — build an image from source_dir, return an opaque build_ref
  #   build_status     — poll until :success / :failure (sync providers answer at once)
  #   deploy_revision! — start the new revision WITHOUT shifting traffic
  #   promote!         — shift 100% traffic to deployment.revision_name
  #   rollback!        — shift traffic back to an older revision
  #   delete_revision! — best-effort cleanup of an unused revision
  class Base
    NOOP_LOG = ->(_line) { }

    attr_reader :project, :runner

    def initialize(project, runner: CommandRunner.new)
      @project = project
      @runner  = runner
    end

    # Short identifier matching project.provider.
    def name
      raise NotImplementedError
    end

    # DeploymentLog#source value for lines streamed from this provider.
    # Must be one of DeploymentLog's allowed sources.
    def log_source
      "system"
    end

    def provision!(log: NOOP_LOG)
      raise NotImplementedError, "#{self.class.name}#provision!"
    end

    # Returns the build_ref (String).
    def build!(deployment, source_dir, log: NOOP_LOG)
      raise NotImplementedError, "#{self.class.name}#build!"
    end

    # Returns a Providers::BuildStatus.
    def build_status(deployment)
      raise NotImplementedError, "#{self.class.name}#build_status"
    end

    def cancel_build!(deployment)
      raise NotImplementedError, "#{self.class.name}#cancel_build!"
    end

    # Returns a Providers::Revision. Must NOT shift traffic.
    def deploy_revision!(deployment, env:, log: NOOP_LOG)
      raise NotImplementedError, "#{self.class.name}#deploy_revision!"
    end

    # Shifts 100% of traffic to deployment.revision_name. Returns the service URL.
    def promote!(deployment, log: NOOP_LOG)
      raise NotImplementedError, "#{self.class.name}#promote!"
    end

    # Shifts 100% of traffic to an older revision. Returns the service URL.
    def rollback!(project, revision_name, log: NOOP_LOG)
      raise NotImplementedError, "#{self.class.name}#rollback!"
    end

    # Best-effort removal of a revision that will never serve traffic.
    def delete_revision!(deployment)
      raise NotImplementedError, "#{self.class.name}#delete_revision!"
    end

    private

    # Runs a command through the injected runner and raises on failure.
    # Subclasses override #classify_failure to map output to error classes.
    def run!(argv, log: NOOP_LOG, env: {}, redact: [], **opts)
      result = runner.call(argv, env: env, log: log, redact: redact, **opts)
      return result if result.success?

      tail = result.output.to_s.lines.last(10).join.strip
      message = "`#{argv.first(3).join(' ')}` failed (exit #{result.exit_status}):\n#{tail}"
      raise classify_failure(result.output.to_s), message
    end

    # Default: everything is permanent. Subclasses refine.
    def classify_failure(_output)
      Providers::Error
    end

    # Convert Kubernetes-style quantities ("512Mi", "1Gi") into what the
    # provider wants. Cloud Run takes them as-is; Docker wants "512m".
    def memory_setting
      project.try(:memory).presence || "512Mi"
    end

    def container_port
      project.port.presence || 3000
    end
  end
end
