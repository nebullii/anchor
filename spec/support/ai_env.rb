# Keeps AI specs hermetic: a developer's real ANTHROPIC_API_KEY /
# OPENAI_API_KEY (or ANCHOR_AI_* overrides) in the shell must never change
# which provider a spec exercises, and never be put on the wire.
# Specs opt in explicitly via enable_anthropic! / enable_openai! (or
# stub_const("ENV", ...)).
AI_ENV_KEYS = %w[
  ANTHROPIC_API_KEY OPENAI_API_KEY
  ANCHOR_AI_PROVIDER ANCHOR_AI_MODEL ANCHOR_AI_MODEL_FAST
].freeze

# Helpers for stubbing provider HTTP calls with WebMock. Nothing here ever
# reaches a real API.
module AiSpecHelpers
  ANTHROPIC_URL = "https://api.anthropic.com/v1/messages".freeze
  OPENAI_URL    = "https://api.openai.com/v1/chat/completions".freeze

  def enable_anthropic!(extra = {})
    stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => "sk-ant-test-key").merge(extra))
  end

  def enable_openai!(extra = {})
    stub_const("ENV", ENV.to_h.merge("OPENAI_API_KEY" => "sk-test-key").merge(extra))
  end

  # Parsed JSON bodies of every stubbed provider request, in order.
  def ai_requests
    @ai_requests ||= []
  end

  def anthropic_payload(text, model: "claude-haiku-4-5-20251001", stop_reason: "end_turn")
    {
      "id" => "msg_test", "type" => "message", "role" => "assistant", "model" => model,
      "content" => [ { "type" => "text", "text" => text } ],
      "stop_reason" => stop_reason,
      "usage" => { "input_tokens" => 10, "output_tokens" => 20 }
    }.to_json
  end

  def stub_anthropic(text = nil, status: 200, body: nil)
    stub_request(:post, ANTHROPIC_URL).to_return do |req|
      ai_requests << JSON.parse(req.body)
      { status: status, body: body || anthropic_payload(text.to_s),
        headers: { "Content-Type" => "application/json" } }
    end
  end

  def stub_openai(text = nil, status: 200)
    stub_request(:post, OPENAI_URL).to_return do |req|
      ai_requests << JSON.parse(req.body)
      { status: status,
        body: { "choices" => [ { "message" => { "content" => text.to_s }, "finish_reason" => "stop" } ] }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
  end
end

RSpec.configure do |config|
  config.include AiSpecHelpers

  config.around do |example|
    saved = AI_ENV_KEYS.to_h { |k| [ k, ENV[k] ] }
    AI_ENV_KEYS.each { |k| ENV.delete(k) }
    begin
      example.run
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
