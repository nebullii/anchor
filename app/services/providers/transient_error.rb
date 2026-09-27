module Providers
  # Retryable provider failure — rate limits, 5xx from the cloud API,
  # network blips. Callers may retry with backoff.
  class TransientError < Error; end
end
