# Signs a user in through the real GitHub OAuth callback (OmniAuth test mode),
# so request specs exercise the genuine session instead of stubbing
# current_user. Hits the GET callback directly, which is not rate-limited.
module AuthHelpers
  def sign_in_via_github(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider:    "github",
      uid:         user.github_id,
      info:        { nickname: user.github_login, name: user.name, email: user.email, image: nil },
      credentials: { token: user.github_token }
    )
    get "/auth/github/callback"
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.after(type: :request) { OmniAuth.config.mock_auth[:github] = nil }
end
