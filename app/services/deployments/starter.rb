module Deployments
  # Starts a new deployment for a project after running the same guards the
  # web UI applies (one active deployment per project, daily/monthly quota,
  # required secrets present). Shared by the JSON API and — once wired up —
  # the HTML controllers, so every entry point enforces identical rules.
  #
  #   result = Deployments::Starter.new(project:, user:, triggered_by: "cli").call
  #   result.success?   # => true
  #   result.deployment # => #<Deployment status: "queued">
  #
  # On failure, result.error_code is one of :deploy_in_progress,
  # :quota_exceeded, :missing_secrets or :invalid_branch and result.message
  # is a user-facing sentence.
  class Starter
    Result = Struct.new(:deployment, :error_code, :message, :missing_secrets, keyword_init: true) do
      def success?
        deployment.present?
      end
    end

    # Git ref names we accept from API callers. Deliberately stricter than
    # git itself: no leading dash (option injection), no "..", no spaces.
    BRANCH_FORMAT = %r{\A(?!-)(?!.*\.\.)[A-Za-z0-9._/\-]{1,255}\z}

    # Trigger used when the requested one isn't accepted by Deployment yet
    # (e.g. "cli" before the state-machine work lands).
    FALLBACK_TRIGGER = "api".freeze

    # `attributes` pre-fills commit metadata (used by "Redeploy" to reuse the
    # last successful commit); PrepareJob overwrites it after cloning.
    def initialize(project:, user:, triggered_by: "manual", branch: nil, attributes: {})
      @project      = project
      @user         = user
      @triggered_by = triggered_by.to_s
      @branch       = branch.presence
      @attributes   = attributes.to_h.symbolize_keys.slice(:commit_sha, :commit_message, :commit_author)
    end

    def call
      if @branch && !@branch.match?(BRANCH_FORMAT)
        return failure(:invalid_branch, "Branch name #{@branch.inspect} is not a valid git branch.")
      end

      if @project.has_active_deployment?
        return failure(:deploy_in_progress, "A deployment is already in progress.")
      end

      missing = @project.missing_required_secrets
      if missing.any?
        return failure(:missing_secrets,
                       "Missing required secrets: #{missing.join(', ')}. Add them before deploying.",
                       missing_secrets: missing)
      end

      # Reserve quota atomically (check + increment in one UPDATE).
      unless @user.consume_deploy_quota!
        return failure(:quota_exceeded,
                       "Daily deployment quota reached (#{User::DAILY_DEPLOY_LIMIT}/day). Try again tomorrow.")
      end

      begin
        deployment = @project.deployments.create!(
          status:       "queued",
          triggered_by: resolved_trigger,
          branch:       @branch || @project.production_branch,
          **@attributes
        )
      rescue ActiveRecord::RecordNotUnique
        # The partial unique index lost a race with a concurrent request.
        @user.release_deploy_quota!
        return failure(:deploy_in_progress, "A deployment is already in progress.")
      end

      DeploymentJob.perform_later(deployment.id)
      Result.new(deployment: deployment)
    end

    private

    def failure(code, message, missing_secrets: [])
      Result.new(error_code: code, message: message, missing_secrets: missing_secrets)
    end

    # Uses the requested trigger when Deployment's inclusion validation
    # accepts it, otherwise falls back to "api" so older schemas still work.
    def resolved_trigger
      allowed = Deployment.validators_on(:triggered_by)
                          .grep(ActiveModel::Validations::InclusionValidator)
                          .flat_map { |v| Array(v.options[:in]) }
      allowed.empty? || allowed.include?(@triggered_by) ? @triggered_by : FALLBACK_TRIGGER
    end
  end
end
