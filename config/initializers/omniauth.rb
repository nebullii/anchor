github_id     = ENV["GITHUB_CLIENT_ID"].presence     || Rails.application.credentials.dig(:github, :client_id)
github_secret = ENV["GITHUB_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:github, :client_secret)

# Validate at server boot (not during asset precompile / rake tasks)
Rails.application.config.after_initialize do
  next if defined?(Rake)  # skip during assets:precompile and other rake tasks
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
end

OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
