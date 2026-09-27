module Ai
  module Adapters
    # OpenAI Chat Completions API — kept as an alternative provider for
    # installs that already have OPENAI_API_KEY configured.
    #
    # JSON schemas are not sent on the wire (the prompt describes the shape);
    # output is validated locally by the caller either way.
    class OpenAi
      URL = "https://api.openai.com/v1/chat/completions".freeze

      def initialize(api_key:)
        @api_key = api_key
      end

      def build_request(system:, prompt:, model:, max_tokens:, json_schema: nil)
        {
          url:     URL,
          headers: { "Authorization" => "Bearer #{@api_key}" },
          body:    {
            model:      model,
            max_tokens: max_tokens,
            messages:   [
              { role: "system", content: system },
              { role: "user",   content: prompt }
            ]
          }
        }
      end

      def parse_response(body)
        choice = Array(body["choices"]).first || {}
        {
          text:        choice.dig("message", "content").to_s,
          model:       body["model"],
          stop_reason: choice["finish_reason"],
          usage:       body["usage"] || {}
        }
      end
    end
  end
end
