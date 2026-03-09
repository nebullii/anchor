require "rails_helper"

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:repositories).dependent(:destroy) }
    it { is_expected.to have_many(:projects).dependent(:destroy) }
    it { is_expected.to have_many(:deployments).through(:projects) }
  end

  describe "validations" do
    subject { build(:user) }
    it { is_expected.to validate_presence_of(:github_id) }
    it { is_expected.to validate_presence_of(:github_login) }

    it "rejects duplicate github_id" do
      create(:user, github_id: "99999")
      duplicate = build(:user, github_id: "99999")
      expect(duplicate).not_to be_valid
    end

    it "rejects duplicate github_login" do
      create(:user, github_login: "octocat")
      duplicate = build(:user, github_login: "octocat")
      expect(duplicate).not_to be_valid
    end
  end

  describe "encryption" do
    it "encrypts github_token at rest" do
      user = create(:user, github_token: "my_secret_token")
      raw = User.connection.select_value(
        "SELECT encrypted_github_token FROM users WHERE id = #{user.id}"
      )
      expect(raw).not_to eq("my_secret_token")
      expect(user.github_token).to eq("my_secret_token")
    end
  end

  describe ".from_omniauth" do
    let(:auth) do
      OmniAuth::AuthHash.new(
        uid: "12345",
        info: { nickname: "octocat", name: "The Octocat", email: "octocat@github.com", image: "https://github.com/octocat.png" },
        credentials: { token: "gho_token123" }
      )
    end

    it "creates a new user from omniauth hash" do
      expect { User.from_omniauth(auth) }.to change(User, :count).by(1)
    end

    it "updates an existing user on re-auth" do
      user = create(:user, github_id: "12345", github_login: "old_login")
      User.from_omniauth(auth)
      expect(user.reload.github_login).to eq("octocat")
    end

    it "stores the oauth token" do
      user = User.from_omniauth(auth)
      expect(user.github_token).to eq("gho_token123")
    end
  end

  describe "#display_name" do
    it "returns name when present" do
      user = build(:user, name: "Ada Lovelace", github_login: "ada")
      expect(user.display_name).to eq("Ada Lovelace")
    end

    it "falls back to github_login when name is blank" do
      user = build(:user, name: nil, github_login: "ada")
      expect(user.display_name).to eq("ada")
    end
  end
end
