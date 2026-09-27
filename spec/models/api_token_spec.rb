require "rails_helper"

RSpec.describe ApiToken, type: :model do
  let(:user) { create(:user) }

  describe ".generate!" do
    it "returns a prefixed plaintext token once and stores only its digest" do
      token = described_class.generate!(user: user, name: "laptop")

      expect(token.plaintext_token).to start_with("anc_")
      expect(token.token_digest).to eq(Digest::SHA256.hexdigest(token.plaintext_token))
      expect(described_class.find(token.id).plaintext_token).to be_nil
    end

    it "requires a name" do
      expect { described_class.generate!(user: user, name: "") }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe ".authenticate" do
    let!(:token) { described_class.generate!(user: user, name: "cli") }

    it "finds the token by its plaintext" do
      expect(described_class.authenticate(token.plaintext_token)).to eq(token)
    end

    it "rejects unknown, blank, or unprefixed tokens" do
      expect(described_class.authenticate("anc_wrong")).to be_nil
      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate(token.plaintext_token.delete_prefix("anc_"))).to be_nil
    end

    it "rejects revoked tokens" do
      token.revoke!
      expect(described_class.authenticate(token.plaintext_token)).to be_nil
    end

    it "updates last_used_at at most once per minute" do
      described_class.authenticate(token.plaintext_token)
      first = token.reload.last_used_at
      expect(first).to be_present

      described_class.authenticate(token.plaintext_token)
      expect(token.reload.last_used_at).to eq(first)

      token.update_column(:last_used_at, 2.minutes.ago)
      described_class.authenticate(token.plaintext_token)
      expect(token.reload.last_used_at).to be > first
    end
  end

  it "is deleted along with its user" do
    described_class.generate!(user: user, name: "cli")
    expect { user.destroy }.to change(described_class, :count).by(-1)
  end
end
