github_id     = ENV["GITHUB_CLIENT_ID"].presence     || Rails.application.credentials.dig(:github, :client_id)
github_secret = ENV["GITHUB_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:github, :client_secret)
google_id     = ENV["GOOGLE_CLIENT_ID"].presence     || Rails.application.credentials.dig(:google, :client_id)
google_secret = ENV["GOOGLE_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:google, :client_secret)

# ── OAuth scopes ─────────────────────────────────────────────────────────── #
# Requested scopes are the blast radius of a stolen Anchor database or a
# compromised worker, so they're kept to what features actually use and are
# overridable per deployment. See docs/threat-model.md → "OAuth scopes".
#
# GitHub (OAuth App scopes are coarse):
#   user:email  — primary email for the account.
#   repo        — clone private repos + create webhooks / commit CI files.
#                 Grants read/write to ALL the user's repos; the long-term fix
#                 is a GitHub App with per-repo installs (contents:read,
#                 metadata:read, webhooks:write, workflows:write).
#   workflow    — only needed to commit .github/workflows (CI/CD setup).
#                 Operators who don't use that feature can drop it via
#                 GITHUB_OAUTH_SCOPE="user:email,repo".
GITHUB_OAUTH_SCOPE = ENV.fetch("GITHUB_OAUTH_SCOPE", "user:email,repo,workflow")

# Google:
#   cloud-platform — full access to every GCP project the user can reach.
#                    Needed today to create service accounts, enable APIs and
#                    deploy. Preferred alternative for BYOC customers: connect
#                    with a narrowly-scoped service account in their project,
#                    or Workload Identity Federation (no long-lived keys).
#   cloudplatformprojects.readonly — list projects in the picker.
GOOGLE_OAUTH_SCOPE = ENV.fetch(
  "GOOGLE_OAUTH_SCOPE",
  "email https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/cloudplatformprojects.readonly"
)

# Validate at server boot (not during asset precompile / rake tasks)
Rails.application.config.after_initialize do
  next if defined?(Rake)
  if Rails.env.production? || Rails.env.development?
    raise "GITHUB_CLIENT_ID is not set"     if ENV["GITHUB_CLIENT_ID"].blank?
    raise "GITHUB_CLIENT_SECRET is not set" if ENV["GITHUB_CLIENT_SECRET"].blank?
  end
end

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           github_id,
           github_secret,
           scope: GITHUB_OAUTH_SCOPE

  provider :google_oauth2,
           google_id,
           google_secret,
           scope: GOOGLE_OAUTH_SCOPE,
           access_type: "offline",
           prompt: "consent select_account",
           include_granted_scopes: true
end

# Request phase is POST-only with a CSRF token (omniauth-rails_csrf_protection),
# which blocks login CSRF via a forged GET /auth/github. The `state` parameter
# (checked by the strategies) binds the callback to this browser's session.
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
OmniAuth.config.logger = Rails.logger
