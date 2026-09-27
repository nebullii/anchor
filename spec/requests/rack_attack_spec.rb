require "rails_helper"

RSpec.describe "Rack::Attack throttling", type: :request do
  around do |example|
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = true
    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store.clear
  end

  # Returns the throttle's discriminator for a synthetic request (nil = not counted).
  def discriminator(name, path, method: "GET", headers: {})
    env = Rack::MockRequest.env_for(path, { method: method, "REMOTE_ADDR" => "1.2.3.4" }.merge(headers))
    Rack::Attack.throttles.fetch(name).block.call(Rack::Attack::Request.new(env))
  end

  describe "req/ip" do
    it "counts ordinary pages by IP" do
      expect(discriminator("req/ip", "/projects")).to eq("1.2.3.4")
    end

    %w[/up /healthz /readyz /webhooks/github /assets/app.css].each do |path|
      it "exempts #{path}" do
        expect(discriminator("req/ip", path, method: "POST")).to be_nil
      end
    end

    it "leaves /api/v1 to the API throttles" do
      expect(discriminator("req/ip", "/api/v1/projects")).to be_nil
    end

    it "does not exempt look-alike paths" do
      expect(discriminator("req/ip", "/webhooks/github-evil")).to eq("1.2.3.4")
      expect(discriminator("req/ip", "/api/v10")).to eq("1.2.3.4")
    end
  end

  describe "api/token" do
    let(:token) { "anc_#{'x' * 32}" }

    it "keys API requests by the SHA-256 digest of the bearer token" do
      key = discriminator("api/token", "/api/v1/me", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" })
      expect(key).to eq(Digest::SHA256.hexdigest(token))
      expect(key).not_to include(token)
    end

    it "ignores requests without a bearer token" do
      expect(discriminator("api/token", "/api/v1/me")).to be_nil
      expect(discriminator("api/token", "/api/v1/me", headers: { "HTTP_AUTHORIZATION" => "Basic abc" })).to be_nil
    end

    it "ignores non-API paths" do
      expect(discriminator("api/token", "/projects", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" })).to be_nil
    end

    it "keeps a per-IP backstop for the API" do
      expect(discriminator("api/ip", "/api/v1/me")).to eq("1.2.3.4")
    end

    it "limits deploys per token" do
      key = discriminator("api/deploy/token", "/api/v1/projects/7/deployments",
                          method: "POST", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" })
      expect(key).to eq(Digest::SHA256.hexdigest(token))
      expect(discriminator("api/deploy/token", "/api/v1/projects/7/deployments",
                           headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" })).to be_nil
    end
  end

  describe "enforcement" do
    it "returns 429 with the API error envelope once a token exceeds its deploy limit" do
      headers = { "Authorization" => "Bearer anc_#{'y' * 32}" }
      30.times { post "/api/v1/projects/1/deployments", headers: headers }
      expect(response).not_to have_http_status(:too_many_requests)

      post "/api/v1/projects/1/deployments", headers: headers
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("3600")
      expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")
    end

    it "does not share limits between tokens" do
      31.times { post "/api/v1/projects/1/deployments", headers: { "Authorization" => "Bearer anc_#{'a' * 32}" } }
      post "/api/v1/projects/1/deployments", headers: { "Authorization" => "Bearer anc_#{'b' * 32}" }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "never throttles webhook deliveries by IP" do
      310.times { post "/webhooks/github", headers: { "X-GitHub-Event" => "ping" } }
      expect(response).to have_http_status(:ok)
    end
  end
end
