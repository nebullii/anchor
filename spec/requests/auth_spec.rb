require "rails_helper"

RSpec.describe "Authentication", type: :request do
  let(:github_auth) do
    OmniAuth::AuthHash.new(
      provider: "github",
      uid: "424242",
      info: { nickname: "octo", name: "Octo Cat", email: "octo@example.com", image: "https://avatars.githubusercontent.com/u/1" },
      credentials: { token: "gho_#{'t' * 36}" }
    )
  end

  around do |example|
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = github_auth
    example.run
  ensure
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  describe "GitHub sign-in" do
    it "logs the user in and stores the token encrypted" do
      get "/auth/github/callback"
      user = User.find_by!(github_id: "424242")

      expect(session[:user_id]).to eq(user.id)
      expect(user.github_token).to eq("gho_#{'t' * 36}")
      raw = User.connection.select_value("SELECT encrypted_github_token FROM users WHERE id = #{user.id}")
      expect(raw).not_to include("gho_")
    end

    it "issues a fresh session id on login (session fixation)" do
      get "/projects" # anonymous request that writes to the session
      anonymous_id = session.id.to_s
      expect(anonymous_id).to be_present

      get "/auth/github/callback"
      expect(session.id.to_s).not_to eq(anonymous_id)
      expect(session[:authenticated_at]).to be_present
    end

    it "returns the user to the page they originally requested" do
      get "/projects"
      get "/auth/github/callback"
      expect(response).to redirect_to("/projects")
      expect(session[:return_to]).to be_nil
    end

    it "fails closed and logs a redacted error when the callback blows up" do
      allow(User).to receive(:from_omniauth).and_raise("boom Bearer abcdefghijklmnop")
      allow(Rails.logger).to receive(:error).and_call_original

      get "/auth/github/callback"
      expect(Rails.logger).to have_received(:error)
        .with(satisfy { |msg| msg.include?("[REDACTED]") && !msg.include?("abcdefghijklmnop") })
      expect(response).to redirect_to(root_path)
      expect(session[:user_id]).to be_nil
    end
  end

  describe "return_to sanitisation" do
    subject(:controller) { AuthController.new }

    it "allows local absolute paths" do
      expect(controller.send(:safe_return_to, "/projects/1?tab=logs")).to eq("/projects/1?tab=logs")
    end

    it "rejects protocol-relative, absolute and backslash URLs" do
      [ "//evil.example", "https://evil.example", "/\\evil.example", "javascript:alert(1)", nil ].each do |path|
        expect(controller.send(:safe_return_to, path)).to be_nil
      end
    end
  end

  describe "logout" do
    it "clears the whole session" do
      get "/auth/github/callback"
      delete "/logout"
      expect(session[:user_id]).to be_nil
      expect(session[:authenticated_at]).to be_nil
    end
  end

  describe "Google connect" do
    before do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "g-1",
        info: { email: "octo@gmail.com" },
        credentials: { token: "ya29.#{'a' * 30}", refresh_token: "1//0#{'r' * 40}", expires_at: 1.hour.from_now.to_i }
      )
    end

    it "requires a signed-in user" do
      get "/auth/google_oauth2/callback"
      expect(response).to redirect_to(root_path)
    end

    it "stores Google tokens for the current user and rotates the session" do
      get "/auth/github/callback"
      before_id = session.id.to_s
      user = User.find_by!(github_id: "424242")

      get "/auth/google_oauth2/callback"
      expect(response).to redirect_to(gcp_projects_path)
      expect(user.reload.google_email).to eq("octo@gmail.com")
      expect(user.google_refresh_token).to start_with("1//0")
      expect(session[:user_id]).to eq(user.id)
      expect(session.id.to_s).not_to eq(before_id)
    end
  end
end
