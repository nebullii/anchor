class WebhookDelivery < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Idempotency ledger for inbound webhooks.                             #
  # One row per (provider, delivery_id). The unique index is the source  #
  # of truth — `claim` relies on it rather than a check-then-insert, so  #
  # concurrent redeliveries can't both win.                              #
  # ------------------------------------------------------------------ #
  RETENTION = 7.days

  validates :provider, :delivery_id, :event, :received_at, presence: true

  # Records the delivery. Returns true the first time a delivery id is seen
  # and false for a duplicate.
  def self.claim(delivery_id:, event:, provider: "github", project_id: nil)
    insert_result = insert(
      {
        provider:    provider,
        delivery_id: delivery_id.to_s.first(255),
        event:       event.to_s.first(255),
        project_id:  project_id,
        received_at: Time.current
      },
      unique_by: %i[provider delivery_id]
    )
    insert_result.rows.any?
  end

  # Deletes ledger rows past retention. GitHub only redelivers recent
  # deliveries, so a week of history is plenty. Intended for a periodic job.
  def self.prune!(older_than: RETENTION.ago)
    where(received_at: ...older_than).delete_all
  end
end
