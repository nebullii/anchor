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

  describe "Active Record Encryption (AES-GCM) with legacy dual-read" do
    # Simulates a row written by the previous release: attr_encrypted CBC
    # ciphertext only, nothing in the GCM `value` column.
    def create_legacy_secret(plaintext)
      secret = create(:secret)
      legacy = Secret.new
      legacy.legacy_value = plaintext
      secret.update_columns(encrypted_value: legacy.encrypted_value,
                            encrypted_value_iv: legacy.encrypted_value_iv)
      Secret.connection.exec_update("UPDATE secrets SET value = NULL WHERE id = #{secret.id}")
      Secret.find(secret.id)
    end

    def raw_row(secret)
      Secret.connection.select_one(
        "SELECT value, encrypted_value, encrypted_value_iv FROM secrets WHERE id = #{secret.id}"
      )
    end

    it "stores new values as authenticated AR ciphertext, never plaintext" do
      secret = create(:secret, value: "gcm_plaintext_value")
      row = raw_row(secret)

      expect(row["value"]).not_to include("gcm_plaintext_value")
      expect(JSON.parse(row["value"])).to include("p", "h") # AR encryption envelope
      expect(Secret.find(secret.id).value).to eq("gcm_plaintext_value")
    end

    it "reads rows that only have the legacy CBC ciphertext" do
      secret = create_legacy_secret("old_school_value")
      expect(secret).to be_legacy_encrypted
      expect(secret.value).to eq("old_school_value")
    end

    it "keeps the legacy columns readable while dual-write is on (rollback safety)" do
      secret = Secret.find(create(:secret, value: "dual_written").id)
      expect(secret.legacy_value).to eq("dual_written")
    end

    it "clears the legacy columns once dual-write is switched off" do
      allow(Secret).to receive(:legacy_dual_write?).and_return(false)
      secret = create(:secret, value: "gcm_only")
      row = raw_row(secret)
      expect(row["encrypted_value"]).to be_nil
      expect(row["encrypted_value_iv"]).to be_nil
      expect(Secret.find(secret.id).value).to eq("gcm_only")
    end

    it "rejects tampered ciphertext instead of returning garbage" do
      secret = create(:secret, value: "integrity_matters")
      envelope = JSON.parse(raw_row(secret)["value"])
      payload  = Base64.strict_decode64(envelope["p"])
      payload[0] = (payload[0].ord ^ 1).chr
      envelope["p"] = Base64.strict_encode64(payload)
      Secret.connection.exec_update(
        "UPDATE secrets SET value = #{Secret.connection.quote(envelope.to_json)} WHERE id = #{secret.id}"
      )

      expect { Secret.find(secret.id).value }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    end

    describe ".reencrypt_legacy!" do
      it "moves legacy rows to AR encryption and is idempotent" do
        legacy  = create_legacy_secret("needs_migration")
        current = create(:secret, value: "already_current")

        expect(Secret.reencrypt_legacy!).to eq(1)
        expect(Secret.reencrypt_legacy!).to eq(0)

        migrated = Secret.find(legacy.id)
        expect(migrated).not_to be_legacy_encrypted
        expect(migrated.value).to eq("needs_migration")
        expect(raw_row(migrated)["value"]).to be_present
        expect(Secret.find(current.id).value).to eq("already_current")
      end
    end
  end

  describe "#masked_value" do
    it "obscures most of the value" do
      secret = build(:secret, value: "supersecret123")
      expect(secret.masked_value).to include("•")
      expect(secret.masked_value).not_to eq("supersecret123")
    end

    it "reveals nothing for short values and only the last 4 chars of long ones" do
      expect(build(:secret, value: "short-pass").masked_value).to eq("••••••••")
      expect(build(:secret, value: "sk_live_abcdefghijkl1234").masked_value).to eq("••••••••1234")
    end

    it "does not leak the value's length" do
      a = build(:secret, value: "a" * 20).masked_value
      b = build(:secret, value: "b" * 200).masked_value
      expect(a.length).to eq(b.length)
    end
  end

  describe "size limit" do
    it "rejects values over 32 KB" do
      expect(build(:secret, value: "x" * (32.kilobytes + 1))).not_to be_valid
      expect(build(:secret, value: "x" * 32.kilobytes)).to be_valid
    end
  end

  describe ".to_env_yaml" do
    it "formats secrets as YAML key-value pairs" do
      project = create(:project)
      create(:secret, project: project, key: "FOO", value: "bar")
      create(:secret, project: project, key: "BAZ", value: "qux")
      result = Secret.to_env_yaml(project)
      parsed = YAML.safe_load(result)
      expect(parsed).to eq("BAZ" => "qux", "FOO" => "bar")
    end

    it "safely handles values containing commas and equals" do
      project = create(:project)
      create(:secret, project: project, key: "DSN", value: "host=db,port=5432")
      result = Secret.to_env_yaml(project)
      parsed = YAML.safe_load(result)
      expect(parsed["DSN"]).to eq("host=db,port=5432")
    end
  end
end
