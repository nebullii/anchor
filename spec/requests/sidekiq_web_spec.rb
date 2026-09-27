require "rails_helper"

RSpec.describe Anchor::SidekiqAdminConstraint, type: :request do
  let(:admin) { create(:user, github_login: "Alice") }
  let(:other) { create(:user, github_login: "mallory") }

  def request_for(user_id)
    instance_double(ActionDispatch::Request, session: { user_id: user_id })
  end

  around do |ex|
    old = ENV["ANCHOR_ADMIN_GITHUB_LOGINS"]
    ENV["ANCHOR_ADMIN_GITHUB_LOGINS"] = " alice , bob"
    ex.run
  ensure
    ENV["ANCHOR_ADMIN_GITHUB_LOGINS"] = old
  end

  it "allows listed GitHub logins (case-insensitive)" do
    expect(described_class.matches?(request_for(admin.id))).to be(true)
  end

  it "denies other users and anonymous requests" do
    expect(described_class.matches?(request_for(other.id))).to be(false)
    expect(described_class.matches?(request_for(nil))).to be(false)
  end

  it "denies everyone when the allowlist is empty" do
    ENV["ANCHOR_ADMIN_GITHUB_LOGINS"] = ""
    expect(described_class.matches?(request_for(admin.id))).to be(false)
  end

  it "hides /sidekiq from anonymous visitors" do
    # Route constraint fails → no route → 404 (not a redirect that reveals the page).
    get "/sidekiq"
    expect(response).to have_http_status(:not_found)
  end
end
