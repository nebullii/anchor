class DeploymentLog < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :deployment

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :message,   presence: true
  validates :level,     inclusion: { in: %w[debug info warn error] }
  validates :source,    inclusion: { in: %w[system cloud_build cloud_run] }
  validates :logged_at, presence: true

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :chronological, -> { order(logged_at: :asc) }
  scope :errors,        -> { where(level: "error") }
  scope :from_build,    -> { where(source: "cloud_build") }
  scope :from_run,      -> { where(source: "cloud_run") }

  # ------------------------------------------------------------------ #
  # Presentation                                                         #
  # ------------------------------------------------------------------ #
  def error?
    level == "error"
  end

  def warn?
    level == "warn"
  end
end
