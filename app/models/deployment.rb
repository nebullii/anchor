class Deployment < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Constants                                                            #
  # ------------------------------------------------------------------ #
  STATUSES = %w[pending cloning detecting building deploying success failed cancelled].freeze

  TERMINAL_STATUSES    = %w[success failed cancelled].freeze
  IN_PROGRESS_STATUSES = %w[pending cloning detecting building deploying].freeze

  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :project
  has_many   :deployment_logs, dependent: :destroy

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :status,       presence: true, inclusion: { in: STATUSES }
  validates :triggered_by, inclusion: { in: %w[manual webhook api] }

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :recent,       -> { order(created_at: :desc) }
  scope :in_progress,  -> { where(status: IN_PROGRESS_STATUSES) }
  scope :terminal,     -> { where(status: TERMINAL_STATUSES) }
  scope :successful,   -> { where(status: "success") }
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
    status == "success"
  end

  def failed?
    status == "failed"
  end

  # Transitions status, sets timing columns, updates parent project,
  # and broadcasts a Turbo Stream status update to the project page.
  def transition_to!(new_status)
    raise ArgumentError, "Unknown status: #{new_status}" unless STATUSES.include?(new_status.to_s)

    attrs = { status: new_status.to_s }
    attrs[:started_at]  = Time.current if new_status.to_s == "cloning" && started_at.nil?
    attrs[:finished_at] = Time.current if TERMINAL_STATUSES.include?(new_status.to_s)

    update!(attrs)
    sync_project_status!
    broadcast_status_update
    self
  end

  # Appends a log line, persists it, and streams it to the deployment show page
  # via Turbo Streams — no custom ActionCable JS required in the view.
  def append_log(message, level: "info", source: "system")
    log = deployment_logs.create!(
      message:   message,
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

  private

  def sync_project_status!
    new_project_status =
      case status
      when "success"   then "active"
      when "failed"    then "error"
      when "cancelled" then project.deployments.where(status: "success").exists? ? "active" : "inactive"
      else                  "building"
      end

    project.update_columns(
      status:     new_project_status,
      latest_url: service_url.presence || project.latest_url
    )
  end

  def broadcast_status_update
    # Update the status badge wherever it appears (project show, deployment index).
    Turbo::StreamsChannel.broadcast_replace_to(
      "project_#{project_id}_deployments",
      target:  "deployment_#{id}_status",
      partial: "deployments/status_badge",
      locals:  { deployment: self }
    )
    # Update the badge on the deployment show page itself.
    Turbo::StreamsChannel.broadcast_replace_to(
      "deployment_#{id}",
      target:  "deployment_#{id}_status",
      partial: "deployments/status_badge",
      locals:  { deployment: self }
    )
    # Update the pipeline steps tracker on every status change.
    Turbo::StreamsChannel.broadcast_replace_to(
      "deployment_#{id}",
      target:  "deployment_pipeline_wrapper",
      partial: "deployments/pipeline_steps",
      locals:  { deployment: self }
    )
    # On terminal states, refresh the outcome panel (URL or error message).
    if terminal?
      Turbo::StreamsChannel.broadcast_replace_to(
        "deployment_#{id}",
        target:  "deployment_outcome",
        partial: "deployments/outcome",
        locals:  { deployment: self }
      )
      # Remove the spinner from the log terminal.
      Turbo::StreamsChannel.broadcast_remove_to(
        "deployment_#{id}_logs",
        target: "log_spinner"
      )
    end
  end
end
