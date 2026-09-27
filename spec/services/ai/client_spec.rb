require "rails_helper"

RSpec.describe Ai::Client do
  describe "provider selection" do
    it "is disabled when no key is configured" do
      client = described_class.new
      expect(client).not_to be_enabled
      expect(client.complete(system: "s", prompt: "p")).to be_nil
      expect(WebMock).not_to have_requested(:any, /.*/)
    end

    it "prefers Anthropic when its key is present" do
      stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => "a", "OPENAI_API_KEY" => "o"))
      expect(described_class.new.provider).to eq("anthropic")
    end

    it "falls back to OpenAI when only its key is present" do
      enable_openai!
      expect(described_class.new.provider).to eq("openai")
    end

    it "honours ANCHOR_AI_PROVIDER" do
      stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => "a", "OPENAI_API_KEY" => "o",
                                       "ANCHOR_AI_PROVIDER" => "openai"))
      expect(described_class.new.provider).to eq("openai")
    end

    it "is disabled when ANCHOR_AI_PROVIDER names a provider without a key" do
      stub_const("ENV", ENV.to_h.merge("OPENAI_API_KEY" => "o", "ANCHOR_AI_PROVIDER" => "anthropic"))
      expect(described_class.new).not_to be_enabled
    end

    it "is disabled when ANCHOR_AI_PROVIDER=none" do
      enable_anthropic!("ANCHOR_AI_PROVIDER" => "none")
      expect(described_class.new).not_to be_enabled
    end
  end

  describe "model selection" do
    before { enable_anthropic! }

    it "uses Sonnet for analysis and Haiku for fast tasks" do
      expect(described_class.new(tier: :analysis).model).to eq("claude-sonnet-5")
      expect(described_class.new(tier: :fast).model).to eq("claude-haiku-4-5-20251001")
    end

    it "lets ANCHOR_AI_MODEL override every tier" do
      enable_anthropic!("ANCHOR_AI_MODEL" => "claude-opus-5")
      expect(described_class.new(tier: :fast).model).to eq("claude-opus-5")
    end

    it "lets ANCHOR_AI_MODEL_FAST override only the fast tier" do
      enable_anthropic!("ANCHOR_AI_MODEL_FAST" => "claude-haiku-4-5")
      expect(described_class.new(tier: :fast).model).to eq("claude-haiku-4-5")
      expect(described_class.new(tier: :analysis).model).to eq("claude-sonnet-5")
    end
  end

  it "keeps the existing gpt-4o-mini model on OpenAI" do
    enable_openai!
    expect(described_class.new(tier: :fast).model).to eq("gpt-4o-mini")
  end

  describe "#complete with Anthropic" do
    before { enable_anthropic! }

    it "sends a Messages API request with the required headers" do
      stub = stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(headers: { "x-api-key" => "sk-ant-test-key", "anthropic-version" => "2023-06-01",
                         "Content-Type" => "application/json" })
        .to_return(status: 200, body: anthropic_payload("hello"))

      response = described_class.new(tier: :fast).complete(system: "sys", prompt: "hi", max_tokens: 50)

      expect(stub).to have_been_requested
      expect(response.text).to eq("hello")
      expect(response.provider).to eq("anthropic")
      expect(response.stop_reason).to eq("end_turn")
    end

    it "puts the system prompt top-level and does not send temperature" do
      stub_anthropic("ok")
      described_class.new(tier: :fast).complete(system: "sys", prompt: "hi", max_tokens: 50)

      body = ai_requests.last
      expect(body["system"]).to eq("sys")
      expect(body["messages"]).to eq([ { "role" => "user", "content" => "hi" } ])
      expect(body["model"]).to eq("claude-haiku-4-5-20251001")
      expect(body).not_to have_key("temperature")
    end

    it "sends a json_schema as output_config.format" do
      stub_anthropic("{}")
      schema = { "type" => "object" }
      described_class.new.complete(system: "s", prompt: "p", json_schema: schema)

      expect(ai_requests.last.dig("output_config", "format"))
        .to eq({ "type" => "json_schema", "schema" => schema })
    end

    it "joins only text blocks from the response" do
      body = { "model" => "m", "stop_reason" => "end_turn",
               "content" => [ { "type" => "thinking", "thinking" => "" },
                             { "type" => "text", "text" => "a" }, { "type" => "text", "text" => "b" } ] }.to_json
      stub_anthropic(body: body)
      expect(described_class.new.complete(system: "s", prompt: "p").text).to eq("ab")
    end

    it "redacts secret values from both system and prompt" do
      stub_anthropic("ok")
      described_class.new.complete(
        system:  "system mentions hunter2-super-secret",
        prompt:  "log: DB password is hunter2-super-secret and token ghp_abcdefghijklmnopqrstuvwxyz123456",
        secrets: [ "hunter2-super-secret" ]
      )

      wire = ai_requests.last.to_json
      expect(wire).not_to include("hunter2-super-secret")
      expect(wire).not_to include("ghp_abcdefghijklmnopqrstuvwxyz123456")
      expect(wire).to include("[REDACTED]")
    end

    it "retries once on 429 then succeeds" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return({ status: 429, body: "{}" }, { status: 200, body: anthropic_payload("second") })

      expect(described_class.new.complete(system: "s", prompt: "p").text).to eq("second")
      expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages").twice
    end

    it "retries once on a timeout then succeeds" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_timeout.then.to_return(status: 200, body: anthropic_payload("ok"))

      expect(described_class.new.complete(system: "s", prompt: "p").text).to eq("ok")
    end

    it "raises after the single retry also fails" do
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(status: 529, body: "{}")

      expect { described_class.new.complete(system: "s", prompt: "p") }
        .to raise_error(Ai::Client::Error, /HTTP 529/)
      expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages").twice
    end

    it "does not retry client errors" do
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(status: 400, body: "{}")

      expect { described_class.new.complete(system: "s", prompt: "p") }.to raise_error(Ai::Client::Error)
      expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages").once
    end

    it "does not leak the response body into the error message" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 400, body: { error: { message: "echo: secret-in-body" } }.to_json)

      expect { described_class.new.complete(system: "s", prompt: "p") }
        .to raise_error(Ai::Client::Error) { |e| expect(e.message).not_to include("secret-in-body") }
    end
  end

  describe "#complete with OpenAI" do
    before { enable_openai! }

    it "sends a chat completions request with bearer auth" do
      stub = stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with(headers: { "Authorization" => "Bearer sk-test-key" })
        .to_return(status: 200, body: { "choices" => [ { "message" => { "content" => "hi" } } ] }.to_json)

      response = described_class.new(tier: :fast).complete(system: "sys", prompt: "p")
      expect(stub).to have_been_requested
      expect(response.text).to eq("hi")
    end

    it "sends the system prompt as the first message" do
      stub_openai("ok")
      described_class.new.complete(system: "sys", prompt: "p")
      expect(ai_requests.last["messages"].first).to eq({ "role" => "system", "content" => "sys" })
    end
  end
end
