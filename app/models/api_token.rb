class ApiToken < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Constants                                                            #
  # ------------------------------------------------------------------ #

  # Every token starts with this prefix so leaked tokens are easy to grep
  # for (and to register with secret scanners).
  PREFIX = "anc_".freeze

  # last_used_at is only rewritten when older than this, so a CLI polling
  # logs every couple of seconds does not turn into a write per request.
  LAST_USED_RESOLUTION = 1.minute

  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :user

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :name,         presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :active,  -> { where(revoked_at: nil) }
  scope :ordered, -> { order(created_at: :desc) }

  # The plaintext token. Only populated on the instance returned by
  # .generate! — it is never persisted and cannot be recovered later.
  attr_reader :plaintext_token

  # ------------------------------------------------------------------ #
  # Class helpers                                                        #
  # ------------------------------------------------------------------ #

  # Creates a new token for +user+ and returns the record with
  # #plaintext_token set. Callers must show that value exactly once.
  def self.generate!(user:, name:)
    raw   = "#{PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    token = create!(user: user, name: name, token_digest: digest(raw))
    token.instance_variable_set(:@plaintext_token, raw)
    token
  end

  def self.digest(raw)
    OpenSSL::Digest::SHA256.hexdigest(raw.to_s)
  end

  # Returns the active token matching +raw+, or nil. The lookup is by
  # digest (so the DB never compares plaintext), and the digests are
  # re-compared in constant time before the token is accepted.
  def self.authenticate(raw)
    raw = raw.to_s
    return nil unless raw.start_with?(PREFIX) && raw.length < 200

    candidate = digest(raw)
    token     = active.find_by(token_digest: candidate)
    return nil unless token
    return nil unless ActiveSupport::SecurityUtils.secure_compare(token.token_digest, candidate)

    token.touch_last_used!
    token
  end

  # ------------------------------------------------------------------ #
  # Instance helpers                                                     #
  # ------------------------------------------------------------------ #

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end

  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_RESOLUTION.ago
    update_column(:last_used_at, Time.current)
  end
end
