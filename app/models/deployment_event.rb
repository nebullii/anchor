class DeploymentEvent < ApplicationRecord
  belongs_to :deployment

  EVENT_TYPES = %w[
    status_changed
    resource_created
    resource_failed
    build_queued
    build_started
    build_failed
    deploy_started
    deploy_failed
    deploy_succeeded
    cancelled
    error_explained
  ].freeze

  validates :event_type,   presence: true, inclusion: { in: EVENT_TYPES }
  validates :occurred_at,  presence: true

  scope :chronological, -> { order(occurred_at: :asc) }
  scope :for_type,      ->(type) { where(event_type: type) }

  # Record a status transition event.
  def self.record_transition(deployment, from:, to:)
    create!(
      deployment:  deployment,
      event_type:  "status_changed",
      from_status: from.to_s,
      to_status:   to.to_s,
      occurred_at: Time.current
    )
  end

  # Record an arbitrary event with optional metadata.
  def self.record(deployment, type, metadata: {})
    create!(
      deployment:  deployment,
      event_type:  type,
      metadata:    metadata,
      occurred_at: Time.current
    )
  end
end
