module Providers
  # A deployed-but-not-yet-promoted revision returned by
  # Providers::Base#deploy_revision!.
  #
  #   name — provider revision identifier (Cloud Run revision, container name)
  #   url  — URL that reaches this revision directly (tagged URL on Cloud Run),
  #          used for health checks before traffic is shifted.
  Revision = Data.define(:name, :url)
end
