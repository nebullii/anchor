class Project < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Constants                                                            #
  # ------------------------------------------------------------------ #
  STATUSES   = %w[inactive active building error].freeze
  FRAMEWORKS = %w[rails node python static docker unknown].freeze
  REGIONS    = %w[
    us-central1 us-east1 us-west1
    europe-west1 europe-west2 europe-west3
    asia-east1 asia-northeast1
  ].freeze

  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :user
  belongs_to :repository

  has_many :deployments,  dependent: :destroy
  has_many :secrets,      dependent: :destroy

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :name,           presence: true
  validates :slug,           presence: true, uniqueness: true,
                             format: { with: /\A[a-z0-9\-]+\z/,
                                       message: "only lowercase letters, numbers, and hyphens" }
  validates :gcp_project_id, presence: true
  validates :gcp_region,     presence: true, inclusion: { in: REGIONS }
  validates :status,         inclusion: { in: STATUSES }
  validates :framework,      inclusion: { in: FRAMEWORKS }, allow_nil: true
  validates :name,           uniqueness: { scope: :user_id, message: "already exists in your account" }

  # ------------------------------------------------------------------ #
  # Callbacks                                                            #
  # ------------------------------------------------------------------ #
  before_validation :set_slug,         on: :create
  before_validation :set_service_name, on: :create

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :active,   -> { where(status: "active") }
  scope :ordered,  -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }

  # ------------------------------------------------------------------ #
  # Instance helpers                                                     #
  # ------------------------------------------------------------------ #

  def latest_deployment
    deployments.order(created_at: :desc).first
  end

  def last_successful_deployment
    deployments.where(status: "success").order(created_at: :desc).first
  end

  # Collect env vars as a hash to pass to Cloud Run.
  def env_vars_hash
    secrets.each_with_object({}) { |s, h| h[s.key] = s.value }
  end

  def deployed?
    latest_url.present?
  end

  def framework_detected?
    framework.present?
  end

  private

  def set_slug
    return if slug.present?
    base = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    self.slug = unique_slug(base)
  end

  def set_service_name
    self.service_name ||= "cl-#{slug}"
  end

  def unique_slug(base)
    candidate = base
    counter   = 1
    while Project.exists?(slug: candidate)
      candidate = "#{base}-#{counter}"
      counter  += 1
    end
    candidate
  end
end
