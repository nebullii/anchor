require "rails_helper"

RSpec.describe Ai::Redaction do
  describe ".redact (fallback)" do
    def redact(text, secrets: [])
      described_class.fallback_redact(text, secrets: secrets)
    end

    it "removes explicit secret values" do
      expect(redact("pw=abc12345 ok", secrets: [ "abc12345" ])).to eq("pw=[REDACTED] ok")
    end

    it "masks the longest secret first when one contains another" do
      out = redact("token supersecretvalue", secrets: %w[secret supersecretvalue])
      expect(out).to eq("token [REDACTED]")
    end

    it "ignores very short secrets to avoid destroying the text" do
      expect(redact("a1 b2", secrets: [ "a1" ])).to eq("a1 b2")
    end

    it "removes credentials embedded in clone URLs" do
      out = redact("cloning https://x-access-token:ghs_abcDEF123456@github.com/o/r.git")
      expect(out).to include("https://[REDACTED]@github.com/o/r.git")
      expect(out).not_to include("ghs_abcDEF123456")
    end

    it "removes bearer tokens" do
      expect(redact("Authorization: Bearer abcdefghijkl.mnop")).to include("Bearer [REDACTED]")
    end

    it "removes well-known key formats" do
      text = "ghp_#{'a' * 36} sk-ant-api03-#{'b' * 20} AKIAABCDEFGHIJKLMNOP anc_#{'c' * 24}"
      out  = redact(text)
      expect(out.scan("[REDACTED]").length).to eq(4)
    end

    it "removes values of sensitive-looking env assignments" do
      out = redact("STRIPE_SECRET_KEY=sk_live_123456789 PORT=8080")
      expect(out).to include("STRIPE_SECRET_KEY=[REDACTED]")
      expect(out).to include("PORT=8080")
    end

    it "removes passwords in database URLs" do
      out = redact("DATABASE_URL is postgres://app:p4ssw0rd@db:5432/app")
      expect(out).not_to include("p4ssw0rd")
    end

    it "removes private key blocks" do
      out = redact("-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----")
      expect(out).to eq("[REDACTED]")
    end

    it "handles nil" do
      expect(described_class.redact(nil)).to eq("")
    end
  end

  describe ".redact delegation" do
    it "uses Security::Redactor when it is defined" do
      redactor = Module.new do
        def self.redact(text, secrets: [])
          "SECURITY:#{text}:#{secrets.join(',')}"
        end
      end
      stub_const("Security::Redactor", redactor)

      expect(described_class.redact("x", secrets: [ "s" ])).to eq("SECURITY:x:s")
    end

    it "falls back when Security::Redactor raises" do
      redactor = Module.new do
        def self.redact(*)
          raise "boom"
        end
      end
      stub_const("Security::Redactor", redactor)

      expect(described_class.redact("pw verysecret", secrets: [ "verysecret" ])).to eq("pw [REDACTED]")
    end
  end

  describe ".secret_values_for" do
    it "returns decrypted project secret values" do
      project = create(:project)
      create(:secret, project: project, key: "API_TOKEN", value: "tok_1234567890")
      expect(described_class.secret_values_for(project)).to include("tok_1234567890")
    end

    it "returns [] for objects without secrets" do
      expect(described_class.secret_values_for(Object.new)).to eq([])
    end
  end
end
