module Providers
  # Permanent provider failure — retrying will not help (bad config, build
  # failure, missing credentials). The deployment should be marked failed.
  class Error < StandardError; end
end
