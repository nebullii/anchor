module Ai
  # Explains a failed deployment in structured form:
  #
  #   { summary:, likely_cause:, fix_steps: [], confidence:, category: }
  #
  # Build logs and error messages are untrusted (they contain arbitrary
  # output from the user's code) so they are redacted, size-capped and
  # delimited before being sent. The model's JSON is validated against
  # SCHEMA; when it is not valid JSON, the raw text is kept as a plain-text
  # explanation (structured: false) rather than being thrown away.
  #
  # Usage:
  #   Ai::ErrorExplainer.new(deployment).call          # => Result | nil
  #   Ai::ErrorExplainer.new(context: ctx).call        # eval harness, no DB
  #
  # Returns nil when AI is not configured or the provider call fails.
  class ErrorExplainer
    MAX_LOG_CHARS   = 8_000
    MAX_ERROR_CHARS = 2_000
    LOG_LINES       = 200
    TIMEOUT         = 20
    MAX_TOKENS      = 1_024

    CATEGORIES = (
      Deployments::ErrorCategorizer::CATEGORIES.keys +
      %w[build_error health_check_failed runtime_crash unknown]
    ).freeze

    CONFIDENCE = %w[high medium low].freeze

    SCHEMA = {
      "type"                 => "object",
      "additionalProperties" => false,
      "required"             => %w[summary likely_cause fix_steps confidence category],
      "properties"           => {
        "summary"      => { "type" => "string", "maxLength" => 500 },
        "likely_cause" => { "type" => "string", "maxLength" => 800 },
        "fix_steps"    => { "type" => "array", "maxItems" => 8,
                            "items" => { "type" => "string", "maxLength" => 400 } },
        "confidence"   => { "type" => "string", "enum" => CONFIDENCE },
        "category"     => { "type" => "string", "enum" => CATEGORIES }
      }
    }.freeze

    # Everything the explainer needs, decoupled from ActiveRecord so the
    # eval harness can build it from YAML fixtures.
    Context = Struct.new(:framework, :branch, :error_message, :logs, :error_category, :secrets,
                         keyword_init: true)

    Result = Struct.new(:summary, :likely_cause, :fix_steps, :confidence, :category,
                        :structured, :raw, :provider, :model, :validation_errors,
                        keyword_init: true) do
      # Single-paragraph rendering stored in deployments.ai_error_explanation
      # (the outcome partial renders it inside one <p>).
      def to_text
        return summary.to_s unless structured

        parts = [ summary.to_s.strip ]
        parts << "Likely cause: #{likely_cause.strip}" if likely_cause.present?
        if fix_steps.present?
          steps = fix_steps.each_with_index.map { |s, i| "#{i + 1}. #{s.strip}" }.join(" ")
          parts << "Fix: #{steps}"
        end
        parts.reject(&:blank?).join(" ")
      end

      def to_h
        {
          "structured"        => structured,
          "summary"           => summary,
          "likely_cause"      => likely_cause,
          "fix_steps"         => fix_steps,
          "confidence"        => confidence,
          "category"          => category,
          "provider"          => provider,
          "model"             => model,
          "validation_errors" => validation_errors,
          "raw"               => raw
        }
      end
    end

    def initialize(deployment = nil, context: nil, client: nil)
      @deployment = deployment
      @context    = context
      @client     = client || Ai::Client.new(tier: :fast)
    end

    def call
      return nil unless @client.enabled?

      ctx      = context
      response = @client.complete(
        system:      system_prompt,
        prompt:      user_message(ctx),
        secrets:     ctx.secrets,
        max_tokens:  MAX_TOKENS,
        timeout:     TIMEOUT,
        json_schema: StructuredOutput.wire_schema(SCHEMA)
      )
      return nil if response.nil? || response.text.blank?

      build_result(response, ctx)
    rescue => e
      Rails.logger.warn("[Ai::ErrorExplainer] Skipped: #{e.class}: #{e.message}")
      nil
    end

    def context
      @context ||= Context.new(
        framework:      @deployment.project.framework.presence || "unknown",
        branch:         @deployment.branch,
        error_message:  @deployment.error_message.to_s,
        logs:           recent_logs,
        error_category: @deployment.try(:error_category),
        secrets:        Redaction.secret_values_for(@deployment.project)
      )
    end

    private

    def build_result(response, ctx)
      raw    = response.text.to_s
      parsed = StructuredOutput.parse(raw, SCHEMA)
      scrub  = ->(s) { Redaction.redact(s.to_s, secrets: ctx.secrets).strip }

      common = {
        raw:               raw.first(Config.settings.max_raw_chars),
        provider:          response.provider,
        model:             response.model,
        validation_errors: parsed.errors
      }

      if parsed.ok?
        data = parsed.data
        Result.new(
          summary:      scrub.(data["summary"]),
          likely_cause: scrub.(data["likely_cause"]),
          fix_steps:    Array(data["fix_steps"]).map { |s| scrub.(s) }.reject(&:blank?),
          confidence:   data["confidence"],
          category:     data["category"],
          structured:   true,
          **common
        )
      else
        # Plain-text fallback: the model answered but not in our schema.
        Result.new(
          summary:    scrub.(raw).first(1_500),
          fix_steps:  [],
          confidence: "low",
          category:   ctx.error_category.presence || "unknown",
          structured: false,
          **common
        )
      end
    end

    def system_prompt
      <<~PROMPT
        You are a deployment expert helping developers fix failed container deployments
        (Docker builds, Google Cloud Run, Artifact Registry, Cloud Build, local Docker).

        Diagnose the failure from the error message and build/runtime logs, then respond with
        ONLY a JSON object, no prose and no markdown fences, with exactly these keys:
          "summary":      one or two sentences a developer can read at a glance
          "likely_cause": the specific root cause, citing the log line, file, env var or command
          "fix_steps":    1-5 short, concrete, ordered steps to fix it
          "confidence":   "high" | "medium" | "low"
          "category":     one of #{CATEGORIES.join(", ")}

        Prefer the earliest real error over follow-on noise. If the logs do not show the cause,
        say so and use confidence "low" — do not invent details.

        #{Untrusted::SYSTEM_RULE}
      PROMPT
    end

    def user_message(ctx)
      <<~MSG
        Framework: #{ctx.framework.presence || "unknown"}
        Branch: #{ctx.branch.presence || "unknown"}
        Rule-based category guess: #{ctx.error_category.presence || "none"}

        Error message:
        #{Untrusted.wrap("error_message", ctx.error_message, max_chars: MAX_ERROR_CHARS)}

        Recent deployment logs (oldest first):
        #{Untrusted.wrap("deployment_logs", ctx.logs, max_chars: MAX_LOG_CHARS, keep: :tail)}
      MSG
    end

    def recent_logs
      @deployment
        .deployment_logs
        .order(logged_at: :desc)
        .limit(LOG_LINES)
        .pluck(:message)
        .reverse
        .join("\n")
    end
  end
end
