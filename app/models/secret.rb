class Secret < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Encryption                                                           #
  # attr_encrypted writes to `encrypted_value` and `encrypted_value_iv`
  # columns — never stores plaintext in the DB.                         #
  # ------------------------------------------------------------------ #
  ENCRYPTION_KEY = proc {
    raw = ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key)
    raise "ENCRYPTION_KEY is not set — add it as an env var or in credentials.yml" if raw.blank?
    Digest::SHA256.digest(raw)[0, 32]
  }

  attr_encrypted :value, key: ENCRYPTION_KEY, algorithm: "aes-256-cbc"

  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :project

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #

  # Keys must be SCREAMING_SNAKE_CASE — safe to pass directly to Cloud Run.
  KEY_FORMAT = /\A[A-Z][A-Z0-9_]*\z/

  # Reserved names that must not be overridden by users.
  RESERVED_KEYS = %w[PORT HOST RAILS_ENV RACK_ENV NODE_ENV].freeze

  validates :key,   presence: true,
                    format: { with: KEY_FORMAT,
                              message: "must be uppercase letters, digits, and underscores (e.g. DATABASE_URL)" },
                    uniqueness: { scope: :project_id, message: "already exists for this project" },
                    exclusion: { in: RESERVED_KEYS, message: "%{value} is reserved by the platform" }
  validates :value, presence: true

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :ordered,        -> { order(:key) }
  scope :for_cloud_run,  -> { ordered }

  # ------------------------------------------------------------------ #
  # Helpers                                                              #
  # ------------------------------------------------------------------ #

  # Returns all secrets for a project as an env var hash { "KEY" => "value" }.
  def self.to_env_hash(project)
    project.secrets.ordered.each_with_object({}) do |secret, hash|
      hash[secret.key] = secret.value
    end
  end

  # Formats secrets as a YAML-safe hash suitable for --env-vars-file.
  # Avoids comma/equals injection that --set-env-vars is vulnerable to.
  def self.to_env_yaml(project)
    to_env_hash(project).transform_values(&:to_s).to_yaml
  end

  # Masks most of the value for safe display in the UI.
  def masked_value
    return "••••••••" if value.blank?
    visible = [value.length / 4, 4].min
    value.first(visible).ljust(value.length, "•")
  end
end
