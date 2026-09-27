require "rails_helper"

RSpec.describe "Health endpoints", type: :request do
  describe "GET /healthz" do
    it "returns ok without auth or dependency checks" do
      expect(ActiveRecord::Base).not_to receive(:connection)
      get "/healthz"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("ok")
    end
  end

  describe "GET /readyz" do
    let(:fresh_process) { { "beat" => Time.now.to_f } }
    let(:queue)         { instance_double(Sidekiq::Queue, name: "deployments", latency: 2.0) }

    before do
      allow(Sidekiq).to receive(:redis).and_yield(double(call: "PONG"))
      allow(Sidekiq::ProcessSet).to receive(:new).and_return([ fresh_process ])
      allow(Sidekiq::Queue).to receive(:all).and_return([ queue ])
    end

    it "returns 200 when DB, Redis, workers and queues are healthy" do
      get "/readyz"
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("ok")
      expect(body["checks"].keys).to contain_exactly("database", "redis", "sidekiq", "queues")
      expect(body["checks"].values).to all(include("ok" => true))
    end

    it "returns 503 when Redis is down, without leaking the error message" do
      allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError, "redis://:secret@10.0.0.1")
      get "/readyz"
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("checks", "redis")).to include("ok" => false, "error" => "RedisClient::CannotConnectError")
      expect(response.body).not_to include("secret")
    end

    it "returns 503 when no worker has a fresh heartbeat" do
      allow(Sidekiq::ProcessSet).to receive(:new).and_return([ { "beat" => 5.minutes.ago.to_f } ])
      get "/readyz"
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("checks", "sidekiq")).to include("ok" => false, "processes" => 0)
    end

    it "returns 503 when queue latency exceeds the threshold" do
      allow(queue).to receive(:latency).and_return(900.0)
      get "/readyz"
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("checks", "queues")).to include("ok" => false, "max_latency" => 900.0)
    end

    it "returns 503 when the database is unreachable" do
      allow(ActiveRecord::Base.connection).to receive(:select_value).and_raise(ActiveRecord::ConnectionNotEstablished)
      get "/readyz"
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("checks", "database", "ok")).to be(false)
    end
  end
end
