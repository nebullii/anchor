Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           ENV["GITHUB_CLIENT_ID"].presence || Rails.application.credentials.dig(:github, :client_id),
           ENV["GITHUB_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:github, :client_secret),
           scope: "user:email,repo"

  google_id     = ENV["GOOGLE_CLIENT_ID"].presence     || Rails.application.credentials.dig(:google, :client_id)
  google_secret = ENV["GOOGLE_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:google, :client_secret)

  if google_id.present? && google_secret.present?
    provider :google_oauth2,
             google_id,
             google_secret,
             scope: "email,https://www.googleapis.com/auth/cloud-platform",
             access_type: "offline",
             prompt: "consent",
             include_granted_scopes: true
  end
end

OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
