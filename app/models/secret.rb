class Secret < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Encryption                                                           #
  #                                                                      #
  # Current: Active Record Encryption (AES-256-GCM, authenticated, key   #
  # rotation) in the `value` column. Keys: config/initializers/          #
  # active_record_encryption.rb.                                         #
  #                                                                      #
  # Legacy: attr_encrypted AES-256-CBC in `encrypted_value` /            #
  # `encrypted_value_iv`, exposed here as `legacy_value`. Migration is   #
  # dual-read: rows without a GCM ciphertext are decrypted from the      #
  # legacy columns. While LEGACY_DUAL_WRITE is on, writes also refresh   #
  # the legacy columns so an older release can still read them after a  #
  # rollback. Plan: docs/threat-model.md → "Encryption at rest".         #
  # ------------------------------------------------------------------ #
  ENCRYPTION_KEY = proc {
    raw = ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key)
    raise "ENCRYPTION_KEY is not set — add it as an env var or in credentials.yml" if raw.blank?
    Digest::SHA256.digest(raw)[0, 32]
  }

  attr_encrypted :legacy_value, attribute: "encrypted_value", key: ENCRYPTION_KEY, algorithm: "aes-256-cbc"

  encrypts :value

  # Keep writing the legacy CBC columns until every running release reads
  # the GCM column. Set ANCHOR_SECRET_LEGACY_WRITES=false to stop (phase 2).
  def self.legacy_dual_write?
    ENV.fetch("ANCHOR_SECRET_LEGACY_WRITES", "true") != "false"
  end

  # Dual-read: GCM ciphertext first, legacy CBC ciphertext as a fallback.
  def value
    super.presence || (legacy_value if encrypted_value.present?)
  end

  def value=(plaintext)
    super
    if self.class.legacy_dual_write? && plaintext.present?
      self.legacy_value = plaintext
    else
      self.encrypted_value    = nil
      self.encrypted_value_iv = nil
    end
  end

  # True when this row still only has the legacy CBC ciphertext.
  def legacy_encrypted?
    read_attribute(:value).blank? && encrypted_value.present?
  end

  # Re-encrypts legacy-only rows with Active Record Encryption. Idempotent
  # and safe to run repeatedly (e.g. `bin/rails runner "Secret.reencrypt_legacy!"`).
  # Returns the number of rows migrated.
  def self.reencrypt_legacy!(batch_size: 500)
    migrated = 0
    where(value: nil).where.not(encrypted_value: nil).find_each(batch_size: batch_size) do |secret|
      secret.with_lock do
        next unless secret.legacy_encrypted?
        secret.value = secret.legacy_value
        secret.save!(validate: false)
        migrated += 1
      end
    end
    migrated
  end

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
  # Cloud Run caps the total env block at 32 KiB; anything bigger is a mistake
  # (or an attempt to bloat the table).
  MAX_VALUE_BYTES = 32.kilobytes

  validates :value, presence: true
  validate  :value_within_size_limit

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

  # Masks the value for safe display in the UI. The mask has a fixed width
  # (so it doesn't leak the length) and reveals at most the last 4
  # characters, and only for values long enough that 4 chars don't matter.
  def masked_value
    return "••••••••" if value.blank? || value.length < 16
    "••••••••#{value.last(4)}"
  end

  private

  def value_within_size_limit
    return if value.nil? || value.bytesize <= MAX_VALUE_BYTES
    errors.add(:value, "is too large (maximum is #{MAX_VALUE_BYTES / 1024} KB)")
  end
end
