class Project < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Constants                                                            #
  # ------------------------------------------------------------------ #
  STATUSES          = %w[inactive active building error].freeze
  FRAMEWORKS        = %w[rails node python fastapi flask django nextjs static docker go bun elixir unknown].freeze
  ANALYSIS_STATUSES = %w[pending analyzing complete failed].freeze
  CICD_STATUSES     = %w[none scanning ready committed failed].freeze
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
  validates :gcp_project_id, presence: true, gcp_project_id: true, unless: :draft?
  validates :gcp_region,     presence: true, inclusion: { in: REGIONS }
  validates :status,          inclusion: { in: STATUSES }
  validates :analysis_status, inclusion: { in: ANALYSIS_STATUSES }
  validates :framework,       inclusion: { in: FRAMEWORKS }, allow_nil: true
  validates :name,           uniqueness: { scope: :user_id, message: "already exists in your account" }

  # ------------------------------------------------------------------ #
  # Callbacks                                                            #
  # ------------------------------------------------------------------ #
  before_validation :set_slug,           on: :create
  before_validation :set_gcp_project_id, on: :create
  before_validation :set_service_name,   on: :create
  before_validation :set_webhook_secret, on: :create
  after_create      :enqueue_provisioning, unless: :draft?

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
    deployments.successful.order(created_at: :desc).first
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

  def analysis_complete?
    analysis_status == "complete" && analysis_result.present?
  end

  def analysis_fresh?
    analysis_complete? && analyzed_at.present? && analyzed_at > 2.hours.ago
  end

  def detected_env_vars
    return [] unless analysis_complete?
    analysis_result["detected_env_vars"] || []
  end

  def missing_required_secrets
    required_keys = detected_env_vars.select { |v| v["required"] }.map { |v| v["key"] }
    existing_keys = secrets.pluck(:key)
    required_keys - existing_keys
  end

  # True if a concurrent active deployment already exists for this project.
  def has_active_deployment?
    deployments.in_progress.exists?
  end

  def cicd_ready?
    cicd_setup_status == "ready"
  end

  def cicd_committed?
    cicd_setup_status == "committed"
  end

  def cicd_scanning?
    cicd_setup_status == "scanning"
  end

  def cicd_failed?
    cicd_setup_status == "failed"
  end

  def cicd_configured?
    cicd_committed? || (cicd_ready? && cicd_files.any?)
  end

  private

  def set_gcp_project_id
    return if draft?
    self.gcp_project_id ||= user.gcp_project_from_key
  end

  def set_slug
    return if slug.present?
    base = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    self.slug = unique_slug(base)
  end

  def set_service_name
    self.service_name ||= "cl-#{slug}"
  end

  def set_webhook_secret
    self.webhook_secret ||= SecureRandom.hex(24)
  end

  def enqueue_provisioning
    Gcp::ProvisionProjectJob.perform_later(id)
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
