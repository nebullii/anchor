module Deployments
  # Raised when a deployment is blocked because a concurrent one is already running.
  class ConcurrentDeploymentError < DeploymentError; end
end
