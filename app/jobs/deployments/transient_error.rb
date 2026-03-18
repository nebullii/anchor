module Deployments
  # Transient failures that may succeed on retry (network blips, rate limits, etc.)
  # These are re-raised so Sidekiq's built-in retry mechanism can handle them.
  class TransientError < DeploymentError; end
end
