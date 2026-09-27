require "rails_helper"

RSpec.describe Deployments::HealthChecker do
  let(:base_url) { "https://rev-abc---svc-xyz.a.run.app" }

  def probe(path: "/", headers: {})
    described_class.new(base_url, path: path, headers: headers).probe
  end

  describe "#probe" do
    it "is healthy on 200" do
      stub_request(:get, "#{base_url}/up").to_return(status: 200, body: "ok")
      result = probe(path: "/up")
      expect(result).to be_healthy
      expect(result.status).to eq(200)
    end

    it "treats an app-level 404 as healthy (the process is answering)" do
      stub_request(:get, "#{base_url}/").to_return(status: 404, body: "<h1>Not Found</h1>")
      expect(probe).to be_healthy
    end

    it "is unhealthy on 5xx" do
      stub_request(:get, "#{base_url}/").to_return(status: 503, body: "Service Unavailable")
      result = probe
      expect(result).not_to be_healthy
      expect(result.detail).to eq("HTTP 503")
    end

    it "is unhealthy on 429 (no instance available)" do
      stub_request(:get, "#{base_url}/").to_return(status: 429, body: "Rate exceeded.")
      expect(probe).not_to be_healthy
    end

    it "is unhealthy when the body is a Google Frontend error page" do
      body = "<title>Error 404 (Not Found)!!1</title><p>The requested URL <code>/</code> was not found on this server."
      stub_request(:get, "#{base_url}/").to_return(status: 404, body: body)
      result = probe
      expect(result).not_to be_healthy
      expect(result.detail).to include("platform proxy")
    end

    it "is unhealthy on connection errors and timeouts" do
      stub_request(:get, "#{base_url}/").to_raise(Errno::ECONNREFUSED)
      expect(probe).not_to be_healthy

      stub_request(:get, "#{base_url}/").to_timeout
      result = probe
      expect(result).not_to be_healthy
      expect(result.status).to be_nil
    end

    it "sends provider-supplied headers" do
      stub = stub_request(:get, "#{base_url}/").with(headers: { "Authorization" => "Bearer id-token" }).to_return(status: 200)
      probe(headers: { "Authorization" => "Bearer id-token" })
      expect(stub).to have_been_requested
    end

    it "joins paths and keeps query strings" do
      stub = stub_request(:get, "#{base_url}/health?full=1").to_return(status: 200)
      described_class.new("#{base_url}/", path: "health?full=1").probe
      expect(stub).to have_been_requested
    end
  end

  it "rejects non-http URLs" do
    expect { described_class.new("ftp://x", path: "/") }.to raise_error(ArgumentError)
  end

  describe "schedule" do
    it "reads attempts and budget from ENV with defaults" do
      expect(described_class.max_attempts).to eq(described_class::DEFAULT_ATTEMPTS)
      stub_const("ENV", ENV.to_h.merge("HEALTH_CHECK_ATTEMPTS" => "3", "HEALTH_CHECK_BUDGET_SECONDS" => "60"))
      expect(described_class.max_attempts).to eq(3)
      expect(described_class.budget_seconds).to eq(60)
    end

    it "fits the default attempts inside the default budget (2-3 minutes)" do
      total = (1...described_class::DEFAULT_ATTEMPTS).sum { |a| described_class.backoff_for(a) }
      expect(total).to be <= described_class::DEFAULT_BUDGET_SECONDS
      expect(described_class::DEFAULT_BUDGET_SECONDS).to be_between(120, 180)
    end
  end
end
