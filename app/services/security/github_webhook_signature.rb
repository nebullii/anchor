module Security
  # Verifies GitHub's X-Hub-Signature-256 header (HMAC-SHA256 of the raw
  # request body, hex encoded, prefixed with "sha256=").
  #
  # The legacy SHA-1 X-Hub-Signature header is intentionally not accepted.
  #
  module GithubWebhookSignature
    PREFIX = "sha256=".freeze

    module_function

    # Constant-time comparison. Returns false (never raises) for a blank
    # secret or a missing / malformed header.
    def valid?(body, secret, header)
      return false if secret.blank? || header.blank?
      return false unless header.start_with?(PREFIX)

      expected = PREFIX + OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, body.to_s)
      ActiveSupport::SecurityUtils.secure_compare(expected, header.to_s)
    end

    # Builds the header value for +body+ — used by specs and local tooling
    # that replays deliveries.
    def sign(body, secret)
      PREFIX + OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, body.to_s)
    end
  end
end
