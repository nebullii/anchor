github_id     = ENV["GITHUB_CLIENT_ID"].presence     || Rails.application.credentials.dig(:github, :client_id)
github_secret = ENV["GITHUB_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:github, :client_secret)
google_id     = ENV["GOOGLE_CLIENT_ID"].presence     || Rails.application.credentials.dig(:google, :client_id)
google_secret = ENV["GOOGLE_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:google, :client_secret)

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
           scope: "user:email,repo,workflow"

  provider :google_oauth2,
           google_id,
           google_secret,
           scope: "email https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/cloudplatformprojects.readonly",
           access_type: "offline",
           prompt: "consent select_account",
           include_granted_scopes: true
end

OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
