module Ai
  module Adapters
    # Anthropic Messages API (POST /v1/messages) over raw HTTP.
    #
    # Raw Faraday rather than the `anthropic` gem to avoid a new dependency;
    # the request surface we need is one endpoint.
    #
    # Notes for current models (Sonnet 5 / Haiku 4.5):
    #   * no `temperature` — Sonnet 5 rejects sampling params with a 400
    #   * no assistant prefill — rejected on the 4.6+ family
    #   * JSON is constrained with output_config.format (structured outputs)
    class Anthropic
      URL     = "https://api.anthropic.com/v1/messages".freeze
      VERSION = "2023-06-01".freeze

      def initialize(api_key:)
        @api_key = api_key
      end

      def build_request(system:, prompt:, model:, max_tokens:, json_schema: nil)
        body = {
          model:      model,
          max_tokens: max_tokens,
          system:     system,
          messages:   [ { role: "user", content: prompt } ]
        }
        if json_schema
          body[:output_config] = { format: { type: "json_schema", schema: json_schema } }
        end

        {
          url:     URL,
          headers: { "x-api-key" => @api_key, "anthropic-version" => VERSION },
          body:    body
        }
      end

      # Concatenates text blocks; ignores thinking/tool blocks.
      def parse_response(body)
        text = Array(body["content"])
          .select { |block| block["type"] == "text" }
          .map    { |block| block["text"].to_s }
          .join

        {
          text:        text,
          model:       body["model"],
          stop_reason: body["stop_reason"],
          usage:       body["usage"] || {}
        }
      end
    end
  end
end
