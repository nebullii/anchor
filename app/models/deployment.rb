class Deployment < ApplicationRecord
  # Raised when a status change is not allowed by TRANSITIONS (e.g. a job tries
  # to move a cancelled deployment to "building"). Jobs treat this as "stop".
  class InvalidTransition < StandardError; end

  # ------------------------------------------------------------------ #
  # Constants                                                            #
  # ------------------------------------------------------------------ #
  STATUSES = %w[
    queued pending
    analyzing cloning detecting
    building deploying health_check
    running success
    failed cancelled rolled_back superseded
  ].freeze

  TERMINAL_STATUSES    = %w[running success failed cancelled rolled_back superseded].freeze
  IN_PROGRESS_STATUSES = %w[queued pending analyzing cloning detecting building deploying health_check].freeze

  TRIGGERS = %w[manual webhook api rollback cli].freeze

  # Statuses every in-progress deployment may always move to.
  ABORT_STATUSES = %w[failed cancelled].freeze

  # Explicit state machine: status => statuses it may move to.
  #
  #   queued → analyzing → building → deploying → health_check → running
  #                                                  └→ rolled_back
  #   (any in-progress status) → failed | cancelled
  #   running → rolled_back   (traffic moved back to an older revision)
  #   running → superseded    (a newer deployment went live)
  #
  # "pending", "cloning", "detecting" and "success" are legacy statuses kept so
  # old rows and jobs keep working. A rollback deployment skips the build and
  # goes queued → deploying directly.
  TRANSITIONS = {
    "queued"       => %w[pending analyzing cloning deploying],
    "pending"      => %w[queued analyzing cloning],
    "analyzing"    => %w[cloning detecting building],
    "cloning"      => %w[analyzing detecting building],
    "detecting"    => %w[building],
    "building"     => %w[deploying],
    "deploying"    => %w[health_check running success rolled_back],
    "health_check" => %w[running success rolled_back],
    "running"      => %w[rolled_back superseded],
    "success"      => %w[rolled_back superseded],
    "failed"       => [],
    "cancelled"    => [],
    "rolled_back"  => [],
    "superseded"   => []
  }.transform_values { |targets| targets.freeze }.freeze

  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :project
  has_many   :deployment_logs,   dependent: :destroy
  has_many   :deployment_events, dependent: :destroy

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :status,       presence: true, inclusion: { in: STATUSES }
  validates :triggered_by, inclusion: { in: TRIGGERS }

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :recent,       -> { order(created_at: :desc) }
  scope :in_progress,  -> { where(status: IN_PROGRESS_STATUSES) }
  scope :terminal,     -> { where(status: TERMINAL_STATUSES) }
  scope :successful,   -> { where(status: %w[running success]) }
  scope :failed,       -> { where(status: "failed") }

  # ------------------------------------------------------------------ #
  # State helpers                                                        #
  # ------------------------------------------------------------------ #

  def in_progress?
    IN_PROGRESS_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def success?
    %w[running success].include?(status)
  end

  def failed?
    status == "failed"
  end

  # Whether the state machine allows moving from the current status to +new_status+.
  def can_transition_to?(new_status)
    new_status = new_status.to_s
    return true if new_status == status
    return true if IN_PROGRESS_STATUSES.include?(status) && ABORT_STATUSES.include?(new_status)
    TRANSITIONS.fetch(status, []).include?(new_status)
  end

  # Transitions status under a row lock, sets timing columns, records a
  # DeploymentEvent, updates the parent project and broadcasts the change.
  #
  # - Same-status calls are a no-op (idempotent — safe for retried jobs).
  # - Illegal moves raise Deployment::InvalidTransition. Because the check runs
  #   after SELECT ... FOR UPDATE, a job racing a user's cancel sees the
  #   committed "cancelled" status and fails the check instead of overwriting it.
  def transition_to!(new_status)
    new_status = new_status.to_s
    raise ArgumentError, "Unknown status: #{new_status}" unless STATUSES.include?(new_status)

    changed = false
    with_lock do
      old_status = status
      next if old_status == new_status

      unless can_transition_to?(new_status)
        raise InvalidTransition, "Deployment #{id}: cannot transition from '#{old_status}' to '#{new_status}'"
      end

      now   = Time.current
      attrs = { status: new_status, status_changed_at: now }
      # Any in-progress status starts the clock (rollbacks skip "analyzing").
      attrs[:started_at]  = now if IN_PROGRESS_STATUSES.include?(new_status) && started_at.nil?
      # Keep the original finish time when a live deployment is later
      # superseded or rolled back.
      attrs[:finished_at] = now if TERMINAL_STATUSES.include?(new_status) && finished_at.nil?

      update!(attrs)
      DeploymentEvent.record_transition(self, from: old_status, to: new_status)
      sync_project_status!
      changed = true
    end

    broadcast_status_update if changed
    self
  end

  # Cancels an in-progress deployment and asks the provider to stop the
  # remote build (best effort — the cancel sticks even if that call fails).
  # Raises InvalidTransition if the deployment already finished.
  def cancel!(reason: "Deployment cancelled by user.")
    return self if status == "cancelled"

    transition_to!("cancelled")
    append_log(reason, level: "warn")
    DeploymentEvent.record(self, "cancelled", metadata: { reason: reason })
    cancel_remote_build
    self
  end

  # Marks the deployment failed with +message+ unless it already reached a
  # terminal status (cancelled, reaped, ...). Returns true if it was failed.
  def fail!(message, category: nil)
    failed = false
    with_lock do
      next if terminal?

      update!(
        error_message:  message,
        error_category: category || Deployments::ErrorCategorizer.categorize(message)
      )
      transition_to!("failed")
      failed = true
    end
    failed
  end

  # Appends a log line, persists it, and streams it to the deployment show page
  # via Turbo Streams — no custom ActionCable JS required in the view.
  def append_log(message, level: "info", source: "system")
    log = deployment_logs.create!(
      message:   redact_log(message),
      level:     level.to_s,
      source:    source.to_s,
      logged_at: Time.current
    )
    # Appends a rendered log line partial into #deployment_logs on the show page.
    Turbo::StreamsChannel.broadcast_append_to(
      "deployment_#{id}_logs",
      target:  "deployment_logs",
      partial: "deployments/log_line",
      locals:  { log: log }
    )
    log
  end

  # Strips project secret values, the owner's GitHub token and common credential
  # patterns before a line is stored or broadcast. Values are loaded once per
  # Deployment instance since jobs append many lines.
  def redact_log(message)
    @log_redaction_secrets ||= begin
      values = Secret.to_env_hash(project).values
      values << project.user&.github_token
      values.compact_blank
    rescue StandardError
      []
    end
    # Also strip ANSI colour codes (docker/npm output) so logs render cleanly.
    Security::Redactor.redact(message.to_s, secrets: @log_redaction_secrets).gsub(/\e\[[\d;]*[A-Za-z]/, "")
  end

  # Wall-clock duration in seconds, nil while still running.
  def duration_seconds
    return nil unless started_at && finished_at
    (finished_at - started_at).round
  end

  def duration_label
    return "—" unless duration_seconds
    mins  = duration_seconds / 60
    secs  = duration_seconds % 60
    mins > 0 ? "#{mins}m #{secs}s" : "#{secs}s"
  end

  # Called once this deployment is serving traffic: every other deployment of
  # the project still marked live becomes "superseded", so exactly one
  # deployment per project reads as running.
  def supersede_previous!
    project.deployments.where(status: %w[running success]).where.not(id: id).find_each do |older|
      older.transition_to!("superseded")
    rescue InvalidTransition
      next
    end
  end

  private

  # Asks the provider (Platform's Providers abstraction) to stop a running
  # build. Never raises: the deployment is already cancelled locally.
  def cancel_remote_build
    return unless defined?(::Providers) && ::Providers.respond_to?(:for)

    provider = ::Providers.for(project)
    provider.cancel_build!(self) if provider.respond_to?(:cancel_build!)
  rescue StandardError => e
    Rails.logger.warn("[Deployment] cancel_build! failed for deployment #{id}: #{e.class}: #{e.message}")
    append_log("Could not stop the remote build: #{e.message}", level: "warn") rescue nil
  end

  def sync_project_status!
    # A deployment that stopped serving (a newer one went live, or traffic was
    # rolled back) says nothing new about the project; the deployment now
    # serving traffic owns the project's status and URL.
    return if %w[superseded rolled_back].include?(status)

    new_project_status =
      case status
      when "running", "success" then "active"
      when "failed", "cancelled"
        # A failed or cancelled deploy never took traffic from the live one.
        if project.deployments.successful.exists? then "active"
        elsif status == "failed"                   then "error"
        else                                            "inactive"
        end
      else "building"
      end

    attrs = { status: new_project_status }
    attrs[:latest_url] = service_url if success? && service_url.present?
    project.update_columns(attrs)
  end

  def broadcast_status_update
    # Update the status badge wherever it appears (project show, deployment index).
    Turbo::StreamsChannel.broadcast_update_to(
      "project_#{project_id}_deployments",
      target:  "deployment_#{id}_status",
      partial: "deployments/status_badge",
      locals:  { deployment: self }
    )
    # Update the badge on the deployment show page itself. `update` swaps the
    # wrapper's contents, so the target id survives for the next broadcast.
    Turbo::StreamsChannel.broadcast_update_to(
      "deployment_#{id}",
      target:  "deployment_#{id}_status",
      partial: "deployments/status_badge",
      locals:  { deployment: self }
    )
    # Update the pipeline steps tracker and the header buttons on every status change.
    Turbo::StreamsChannel.broadcast_update_to(
      "deployment_#{id}",
      target:  "deployment_actions",
      partial: "deployments/actions",
      locals:  { deployment: self }
    )
    Turbo::StreamsChannel.broadcast_update_to(
      "deployment_#{id}",
      target:  "deployment_pipeline_wrapper",
      partial: "deployments/pipeline_steps",
      locals:  { deployment: self }
    )
    # The outcome panel shows the current step while in progress and the URL
    # or error once finished, so refresh it on every change.
    Turbo::StreamsChannel.broadcast_update_to(
      "deployment_#{id}",
      target:  "deployment_outcome",
      partial: "deployments/outcome",
      locals:  { deployment: self }
    )
    if terminal?
      # Remove the spinner from the log terminal.
      Turbo::StreamsChannel.broadcast_remove_to(
        "deployment_#{id}_logs",
        target: "log_spinner"
      )
    end
  end
end
