module Ai
  # Provider-agnostic LLM client.
  #
  # Every Anchor AI feature talks to an LLM through this class so that the
  # following guarantees hold in exactly one place:
  #
  #   * Redaction — system prompt and user prompt are passed through
  #     Ai::Redaction (Security::Redactor when present) with the project's
  #     secret values before leaving the process.
  #   * Timeouts — every call has an open + read timeout.
  #   * Retry — exactly one retry on 408/409/429/5xx/529 and connection errors.
  #   * No-op — when no provider is configured, #complete returns nil and
  #     never touches the network.
  #
  # Usage:
  #   client = Ai::Client.new(tier: :fast)
  #   response = client.complete(system: "...", prompt: "...", secrets: ["s3cr3t"])
  #   response&.text
  #
  # Raises Ai::Client::Error for non-retryable failures or when the retry
  # also fails. Callers are expected to rescue and degrade gracefully.
  class Client
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end
    end

    RETRYABLE_STATUSES = [ 408, 409, 429, 500, 502, 503, 504, 529 ].freeze
    RETRYABLE_ERRORS   = [ Faraday::TimeoutError, Faraday::ConnectionFailed ].freeze
    MAX_ATTEMPTS       = 2

    Response = Struct.new(:text, :provider, :model, :stop_reason, :usage, keyword_init: true)

    ADAPTERS = {
      "anthropic" => "Ai::Adapters::Anthropic",
      "openai"    => "Ai::Adapters::OpenAi"
    }.freeze

    attr_reader :tier, :provider

    # The body of the most recent request exactly as sent (post-redaction).
    # Used by the eval harness to prove secrets never reach the provider.
    attr_reader :last_request_body

    # provider: override the ENV-derived provider ("anthropic" | "openai").
    # model:    override the tier's default model.
    def initialize(tier: :analysis, provider: nil, model: nil)
      @tier     = tier
      @provider = provider || Config.provider
      @model    = model
    end

    def enabled?
      @provider.present? && Config.api_key_for(@provider).present?
    end

    def model
      return nil unless @provider
      @model || Config.model_for(@provider, @tier)
    end

    # system:      trusted instructions (still redacted — defence in depth)
    # prompt:      the user turn; may contain delimited untrusted content
    # secrets:     plaintext secret values that must never reach the provider
    # json_schema: optional JSON Schema; providers that support constrained
    #              decoding use it, others rely on the prompt. Output is
    #              always validated locally by the caller.
    def complete(system:, prompt:, secrets: [], max_tokens: 1024, timeout: 30, json_schema: nil)
      return nil unless enabled?

      request = adapter.build_request(
        system:      Redaction.redact(system, secrets: secrets),
        prompt:      Redaction.redact(prompt, secrets: secrets),
        model:       model,
        max_tokens:  max_tokens,
        json_schema: json_schema
      )
      @last_request_body = request[:body]

      body = perform_with_retry(request, timeout)
      parsed = adapter.parse_response(body)

      Response.new(
        text:        parsed[:text].to_s,
        provider:    @provider,
        model:       parsed[:model].presence || model,
        stop_reason: parsed[:stop_reason],
        usage:       parsed[:usage] || {}
      )
    end

    private

    def adapter
      @adapter ||= ADAPTERS.fetch(@provider).constantize.new(api_key: Config.api_key_for(@provider))
    end

    def perform_with_retry(request, timeout)
      attempts = 0
      begin
        attempts += 1
        perform(request, timeout)
      rescue Error, *RETRYABLE_ERRORS => e
        retryable = !e.is_a?(Error) || RETRYABLE_STATUSES.include?(e.status)
        if retryable && attempts < MAX_ATTEMPTS
          delay = Config.settings.retry_delay.to_f
          sleep(delay) if delay.positive?
          retry
        end
        raise e.is_a?(Error) ? e : Error.new("#{@provider} request failed: #{e.class}")
      end
    end

    def perform(request, timeout)
      conn = Faraday.new(url: request[:url]) do |f|
        f.options.timeout      = timeout
        f.options.open_timeout = Config.settings.open_timeout
      end

      response = conn.post do |req|
        request[:headers].each { |k, v| req.headers[k] = v }
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(request[:body])
      end

      unless response.success?
        # Never include the response body verbatim — providers sometimes
        # echo parts of the request back in error messages.
        raise Error.new("#{@provider} returned HTTP #{response.status}", status: response.status)
      end

      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise Error.new("#{@provider} returned a non-JSON body")
    end
  end
end
