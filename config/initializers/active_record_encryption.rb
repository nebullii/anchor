# Active Record Encryption (AES-256-GCM, authenticated, supports key rotation).
#
# Used by Secret#value (and, in a follow-up, the User token columns) in place
# of attr_encrypted's AES-256-CBC. See docs/threat-model.md → "Encryption at rest".
#
# Key sources, in order:
#   1. Explicit env vars (recommended for production):
#        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY        comma-separated; the LAST
#                                                    key encrypts, all decrypt
#                                                    (this is how you rotate)
#        ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
#        ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
#      Generate with: bin/rails db:encryption:init
#   2. Rails credentials (active_record_encryption.*) — picked up by Rails itself.
#   3. Derived from ENCRYPTION_KEY with PBKDF2-SHA256 and per-purpose salts, so
#      existing deployments work without new configuration. Rotating
#      ENCRYPTION_KEY then requires listing the old derived key — prefer (1).
#
# Nothing here raises: an app booting without keys (e.g. assets:precompile)
# only fails when it actually encrypts or decrypts.
Rails.application.configure do
  env_keys = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].to_s.split(",").map(&:strip).reject(&:empty?)
  derived  = nil

  base = ENV["ENCRYPTION_KEY"].presence
  if base && (env_keys.empty? || ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].blank?)
    generator = ActiveSupport::KeyGenerator.new(base, iterations: 100_000, hash_digest_class: OpenSSL::Digest::SHA256)
    derived = ->(purpose) { generator.generate_key("anchor/active_record_encryption/#{purpose}", 32).unpack1("H*") }
  end

  primary       = env_keys.presence || derived&.call("primary")
  deterministic = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].presence || derived&.call("deterministic")
  salt          = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].presence || derived&.call("salt")

  config.active_record.encryption.primary_key         = primary       if primary
  config.active_record.encryption.deterministic_key   = deterministic if deterministic
  config.active_record.encryption.key_derivation_salt = salt          if salt

  # Encrypted columns hold ciphertext only; never fall back to reading
  # plaintext that happens to be in an encrypted column.
  config.active_record.encryption.support_unencrypted_data = false
end
