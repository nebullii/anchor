require "rails_helper"

# Token management UI lives on the Settings page (session-authenticated).
RSpec.describe "Settings API tokens", type: :request do
  let(:user) { create(:user) }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  it "creates a token and shows the plaintext exactly once" do
    expect {
      post "/settings/api_tokens", params: { name: "laptop" }
    }.to change { ApiToken.where(user: user).count }.by(1)

    token = ApiToken.last
    expect(response).to have_http_status(:created)
    expect(response.headers["Cache-Control"]).to include("no-store")
    shown = response.body[/anc_[A-Za-z0-9_\-]+/]
    expect(ApiToken.digest(shown)).to eq(token.token_digest)

    get "/settings"
    expect(response.body).to include("laptop")
    expect(response.body).not_to include(shown)
  end

  it "defaults the token name" do
    post "/settings/api_tokens"
    expect(ApiToken.last.name).to eq("CLI token")
  end

  it "revokes a token" do
    token = ApiToken.generate!(user: user, name: "old")
    delete "/settings/api_tokens/#{token.id}"
    expect(response).to redirect_to("/settings")
    expect(token.reload).to be_revoked
    expect(ApiToken.authenticate(token.plaintext_token)).to be_nil
  end

  it "cannot revoke another user's token" do
    token = ApiToken.generate!(user: create(:user), name: "theirs")
    delete "/settings/api_tokens/#{token.id}"
    expect(response).to have_http_status(:not_found)
    expect(token.reload).not_to be_revoked
  end
end
