module Deployments
  # One-click rollback: shift traffic back to a previously healthy revision.
  #
  #   Deployments::Rollback.new(project: project, user: current_user).call
  #   Deployments::Rollback.new(project: project, target: deployment, user: current_user).call
  #
  # Creates a new Deployment (triggered_by "rollback", status "queued") that
  # records the target's revision/commit, and enqueues RollbackJob to perform
  # the traffic shift. No rebuild happens — the old revision is reused, so a
  # rollback typically completes in seconds.
  #
  # Target selection (when not given): the most recent previously successful
  # deployment that has a revision_name different from the one currently
  # serving traffic.
  #
  class Rollback
    class Error < StandardError; end

    # Statuses of deployments whose revision passed a health check at some point.
    TARGET_STATUSES = %w[running success rolled_back superseded].freeze
    # Statuses meaning "this revision is what users are hitting right now".
    LIVE_STATUSES   = %w[running success].freeze

    # The deployment currently receiving traffic for the project (nil if none).
    def self.current_deployment(project)
      project.deployments
             .where(status: LIVE_STATUSES)
             .where.not(revision_name: [ nil, "" ])
             .order(Arel.sql("COALESCE(finished_at, created_at) DESC"), id: :desc)
             .first
    end

    # Default rollback target: newest healthy deployment whose revision differs
    # from the live one.
    def self.default_target(project, current = current_deployment(project))
      scope = project.deployments
                     .where(status: TARGET_STATUSES)
                     .where.not(revision_name: [ nil, "" ])
      if current
        scope = scope.where.not(id: current.id).where.not(revision_name: current.revision_name)
      end
      scope.order(created_at: :desc, id: :desc).first
    end

    # Whether the UI should offer "Roll back to this deployment".
    def self.eligible?(deployment)
      return false if deployment.revision_name.blank?
      return false unless TARGET_STATUSES.include?(deployment.status)

      project = deployment.project
      return false if project.deployments.in_progress.exists?

      current = current_deployment(project)
      current.present? && current.id != deployment.id && current.revision_name != deployment.revision_name
    end

    def initialize(project:, user:, target: nil)
      @project = project
      @user    = user
      @target  = target
    end

    # Returns the new rollback Deployment. Raises Rollback::Error when the
    # rollback cannot be started (nothing to roll back to, deploy in progress…).
    def call
      deployment = @project.with_lock do
        if @project.deployments.in_progress.exists?
          raise Error, "A deployment is already in progress. Wait for it to finish or cancel it first."
        end

        current = self.class.current_deployment(@project)
        target  = resolve_target(current)

        @project.deployments.create!(
          status:         "queued",
          triggered_by:   "rollback",
          branch:         target.branch,
          commit_sha:     target.commit_sha,
          commit_message: rollback_message(target),
          commit_author:  @user.try(:github_login) || target.commit_author,
          image_url:      target.image_url,
          revision_name:  target.revision_name,
          revision_url:   target.revision_url
        )
      end

      deployment.append_log(
        "Rollback requested by #{@user.try(:github_login) || 'system'}: " \
        "shifting traffic to revision #{deployment.revision_name}."
      )
      RollbackJob.perform_later(deployment.id)
      deployment
    end

    private

    def resolve_target(current)
      target = @target ? explicit_target : self.class.default_target(@project, current)
      raise Error, "No previous healthy deployment with a revision to roll back to." unless target

      if current && current.revision_name == target.revision_name
        raise Error, "Revision #{target.revision_name} is already serving traffic."
      end
      target
    end

    def explicit_target
      target = @target.is_a?(Deployment) ? @target : @project.deployments.find_by(id: @target)
      raise Error, "Deployment not found for this project." unless target && target.project_id == @project.id
      unless TARGET_STATUSES.include?(target.status) && target.revision_name.present?
        raise Error, "Deployment ##{target.id} (#{target.status}) never went live, so it cannot be a rollback target."
      end
      target
    end

    def rollback_message(target)
      summary = target.commit_message.to_s.lines.first.to_s.strip
      "Rollback to ##{target.id}#{summary.present? ? " (#{summary})" : ''}".truncate(250)
    end
  end
end
