require "rails_helper"

RSpec.describe Secret, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    subject { build(:secret) }

    it { is_expected.to validate_presence_of(:key) }
    it { is_expected.to validate_presence_of(:value) }

    it "requires SCREAMING_SNAKE_CASE keys" do
      expect(build(:secret, key: "lowercase")).not_to be_valid
      expect(build(:secret, key: "VALID_KEY")).to be_valid
      expect(build(:secret, key: "123INVALID")).not_to be_valid
    end

    it "rejects reserved keys" do
      Secret::RESERVED_KEYS.each do |reserved|
        expect(build(:secret, key: reserved)).not_to be_valid
      end
    end

    it "enforces uniqueness of key per project" do
      secret = create(:secret, key: "MY_KEY")
      duplicate = build(:secret, project: secret.project, key: "MY_KEY")
      expect(duplicate).not_to be_valid
    end
  end

  describe "encryption" do
    it "encrypts value at rest" do
      secret = create(:secret, value: "plaintext_value")
      raw = Secret.connection.select_value(
        "SELECT encrypted_value FROM secrets WHERE id = #{secret.id}"
      )
      expect(raw).not_to eq("plaintext_value")
      expect(secret.value).to eq("plaintext_value")
    end
  end

  describe "#masked_value" do
    it "obscures most of the value" do
      secret = build(:secret, value: "supersecret123")
      expect(secret.masked_value).to include("•")
      expect(secret.masked_value).not_to eq("supersecret123")
    end
  end

  describe ".to_cloud_run_env_string" do
    it "formats secrets as KEY=value pairs" do
      project = create(:project)
      create(:secret, project: project, key: "FOO", value: "bar")
      create(:secret, project: project, key: "BAZ", value: "qux")
      result = Secret.to_cloud_run_env_string(project)
      expect(result).to include("FOO=bar")
      expect(result).to include("BAZ=qux")
    end
  end
end
