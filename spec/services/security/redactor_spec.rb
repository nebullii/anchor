require "rails_helper"

RSpec.describe Security::Redactor do
  def redact(text, secrets: [])
    described_class.redact(text, secrets: secrets)
  end

  describe "explicit secret values" do
    it "removes every occurrence of a provided secret" do
      out = redact("db=hunter2hunter2 and again hunter2hunter2", secrets: [ "hunter2hunter2" ])
      expect(out).to eq("db=[REDACTED] and again [REDACTED]")
    end

    it "accepts a hash of env vars and redacts the values" do
      out = redact("connecting to postgres://app@db/prod with s3cr3tvalue",
                   secrets: { "DB_PASS" => "s3cr3tvalue" })
      expect(out).not_to include("s3cr3tvalue")
    end

    it "redacts URL-encoded forms of a secret" do
      out = redact("url=https://x/?k=p%40ss%2Fw0rd%21&x=1", secrets: [ "p@ss/w0rd!" ])
      expect(out).not_to include("p%40ss%2Fw0rd")
    end

    it "redacts longer secrets before shorter ones they contain" do
      out = redact("value: abcdef123456", secrets: [ "abcdef", "abcdef123456" ])
      expect(out).to eq("value: [REDACTED]")
    end

    it "ignores very short or blank values to keep logs readable" do
      out = redact("status true port 80", secrets: [ "true", "80", "", nil ])
      expect(out).to eq("status true port 80")
    end
  end

  describe "credential patterns" do
    it "redacts tokens embedded in clone URLs" do
      out = redact("fatal: unable to access 'https://x-access-token:ghs_abc123DEF456ghi789JKL@github.com/o/r.git/'")
      expect(out).to include("https://[REDACTED]@github.com/o/r.git")
      expect(out).not_to include("ghs_abc123")
    end

    it "redacts user:password in database URLs" do
      out = redact("DATABASE_URL is postgres://admin:Sup3rS3cret@10.0.0.1:5432/app")
      expect(out).to include("postgres://[REDACTED]@10.0.0.1:5432/app")
    end

    it "does not touch URLs without credentials" do
      text = "Live at https://app-abc.run.app:443/path@v2 and http://localhost:3000"
      expect(redact(text)).to eq(text)
    end

    it "redacts bearer tokens" do
      out = redact("curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig'")
      expect(out).to eq("curl -H 'Authorization: Bearer [REDACTED]'")
    end

    it "redacts GitHub 'Authorization: token' headers" do
      out = redact("Authorization: token 0123456789abcdef0123456789abcdef01234567")
      expect(out).to eq("Authorization: token [REDACTED]")
    end

    {
      "classic GitHub PAT"      => "ghp_#{'a1B2' * 9}",
      "GitHub OAuth token"      => "gho_#{'Z9y8' * 9}",
      "GitHub app token"        => "ghs_#{'Q1w2' * 9}",
      "fine-grained GitHub PAT" => "github_pat_11ABCDEFG0_#{'x' * 60}",
      "Google API key"          => "AIza#{'S' * 35}",
      "Google OAuth token"      => "ya29.a0AfH6SM#{'b' * 40}",
      "OpenAI key"              => "sk-#{'A' * 48}",
      "OpenAI project key"      => "sk-proj-#{'B1' * 30}",
      "Anthropic key"           => "sk-ant-api03-#{'C' * 80}",
      "AWS access key id"       => "AKIAIOSFODNN7EXAMPLE",
      "Stripe secret"           => "sk_live_#{'4' * 24}",
      "Anchor API token"        => "anc_#{'k' * 32}"
    }.each do |label, token|
      it "redacts a #{label}" do
        out = redact("error: token #{token} rejected")
        expect(out).not_to include(token)
        expect(out).to include(Security::Redactor::PLACEHOLDER)
      end
    end

    it "redacts PEM private key blocks" do
      pem = <<~PEM
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA7Vx
        abcdefghijklmnop
        -----END RSA PRIVATE KEY-----
      PEM
      out = redact("loaded key:\n#{pem}done")
      expect(out).not_to include("MIIEowIBAAKCAQEA7Vx")
      expect(out).to include("done")
    end

    it "redacts a truncated private key block" do
      out = redact("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC")
      expect(out).not_to include("MIIEvQIBADANB")
    end

    it "redacts the private key of a service-account JSON" do
      json = {
        type: "service_account",
        project_id: "demo",
        private_key_id: "0123456789abcdef0123456789abcdef01234567",
        private_key: "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQE\n-----END PRIVATE KEY-----\n",
        client_email: "anchor@demo.iam.gserviceaccount.com"
      }.to_json

      out = redact(json)
      expect(out).not_to include("MIIEvQIBADANBgkqhkiG9w0BAQE")
      expect(out).not_to include("0123456789abcdef0123456789abcdef01234567")
      expect(out).to include("anchor@demo.iam.gserviceaccount.com")
    end

    it "redacts KEY=value assignments whose name marks them as secret" do
      out = redact("export STRIPE_SECRET_KEY=abc123xyz789 DATABASE_PASSWORD='p4ssw0rd!' PORT=8080")
      expect(out).to include("STRIPE_SECRET_KEY=[REDACTED]")
      expect(out).to include("DATABASE_PASSWORD='[REDACTED]'")
      expect(out).to include("PORT=8080")
    end
  end

  describe "robustness" do
    it "returns nil for nil" do
      expect(redact(nil)).to be_nil
    end

    it "does not mutate its argument" do
      text = +"Bearer abcdefghijklmnop"
      redact(text)
      expect(text).to eq("Bearer abcdefghijklmnop")
    end

    it "handles invalid byte sequences" do
      text = "bad \xFF bytes ghp_#{'a' * 36}".dup.force_encoding("UTF-8")
      expect { redact(text) }.not_to raise_error
      expect(redact(text)).not_to include("ghp_")
    end

    it "leaves ordinary log lines untouched" do
      text = "Step 3/9 : RUN bundle install --jobs 4\nSuccessfully built 1a2b3c4d\nTokens used: 512"
      expect(redact(text)).to eq(text)
    end

    it "is idempotent" do
      once = redact("Bearer abcdefghijklmnop SECRET_TOKEN=xyz12345")
      expect(redact(once)).to eq(once)
    end
  end
end
