module Deployments
  class DeploymentError < StandardError; end

  # Transient failures that may succeed on retry (network blips, rate limits, etc.)
  # These are re-raised so Sidekiq's built-in retry mechanism can handle them.
  class TransientError < DeploymentError; end

  # Raised when a deployment is blocked because a concurrent one is already running.
  class ConcurrentDeploymentError < DeploymentError; end
end
