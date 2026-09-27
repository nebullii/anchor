module Ai
  # Enriches the deterministic repository analysis with AI insights.
  #
  # Trust model:
  #   * The deterministic detectors are the source of truth. On any
  #     conflict (framework, port, env var already detected) the
  #     deterministic value wins; the AI may only fill gaps.
  #   * README and file tree are untrusted repo content: redacted,
  #     size-capped, and delimited with <untrusted_input>.
  #   * The model's JSON is validated key-by-key against SCHEMA. Invalid
  #     keys and invalid list items are dropped (and recorded) instead of
  #     discarding the whole response.
  #
  # The merged result carries an "ai_enrichment" entry with provider,
  # model, the raw response and the accepted (parsed) data for audit.
  #
  # Degrades gracefully: with no provider configured, or on any failure,
  # the original analysis result is returned unchanged.
  class RepositoryAnalyzer
    TIMEOUT          = 45
    MAX_TOKENS       = 2_048
    MAX_README_CHARS = 4_000
    MAX_TREE_PATHS   = 150

    ENV_KEY_PATTERN = "^[A-Z][A-Z0-9_]*$".freeze

    SCHEMA = {
      "type"       => "object",
      "properties" => {
        "app_description"     => { "type" => "string", "maxLength" => 300 },
        "confidence"          => { "type" => "string", "enum" => %w[high medium low] },
        "framework_notes"     => { "type" => "string", "maxLength" => 500 },
        "framework"           => { "type" => "string", "maxLength" => 40, "pattern" => "^[a-z0-9_.-]+$" },
        "port"                => { "type" => "integer" },
        "warnings"            => { "type" => "array", "maxItems" => 10,
                                   "items" => { "type" => "string", "maxLength" => 300 } },
        "additional_env_vars" => {
          "type" => "array", "maxItems" => 20,
          "items" => {
            "type"       => "object",
            "required"   => %w[key],
            "properties" => {
              "key"         => { "type" => "string", "maxLength" => 80, "pattern" => ENV_KEY_PATTERN },
              "required"    => { "type" => "boolean" },
              "source"      => { "type" => "string", "maxLength" => 80 },
              "description" => { "type" => "string", "maxLength" => 300 }
            }
          }
        },
        "env_var_suggestions" => {
          "type" => "array", "maxItems" => 30,
          "items" => {
            "type"       => "object",
            "required"   => %w[key],
            "properties" => {
              "key"        => { "type" => "string", "maxLength" => 80, "pattern" => ENV_KEY_PATTERN },
              "confidence" => { "type" => "string" },
              "required"   => { "type" => "boolean" },
              "reason"     => { "type" => "string", "maxLength" => 300 }
            }
          }
        }
      }
    }.freeze

    def initialize(analysis_result, file_tree: [], readme: nil, secrets: [], client: nil)
      @analysis_result = analysis_result
      @file_tree       = Array(file_tree)
      @readme          = readme
      @secrets         = Array(secrets)
      @client          = client || Ai::Client.new(tier: :analysis)
    end

    # Returns an enriched copy of analysis_result (Hash), or the original
    # when AI is unavailable / not configured / returns nothing usable.
    def call
      return @analysis_result unless @client.enabled?

      response = @client.complete(
        system:     system_prompt,
        prompt:     user_message,
        secrets:    @secrets,
        max_tokens: MAX_TOKENS,
        timeout:    TIMEOUT
      )
      return @analysis_result if response.nil? || response.text.blank?

      json = StructuredOutput.extract_json(response.text)
      return @analysis_result unless json.is_a?(Hash)

      accepted, errors = validate_per_key(json)
      return @analysis_result if accepted.empty?

      merge_enrichment(@analysis_result, accepted, response: response, errors: errors)
    rescue => e
      Rails.logger.warn("[Ai::RepositoryAnalyzer] Enrichment skipped: #{e.class}: #{e.message}")
      @analysis_result
    end

    private

    def system_prompt
      <<~PROMPT
        You are an expert DevOps engineer reviewing an application repository before it is
        containerised and deployed. You receive a deterministic analysis (trusted) plus the
        repository's file tree and README (untrusted).

        The deterministic analysis is authoritative. Do not contradict it; only add
        information it is missing. Be concise. Respond with ONLY a JSON object — no prose,
        no markdown fences.

        #{Untrusted::SYSTEM_RULE}
      PROMPT
    end

    def user_message
      parts = []
      parts << "## Deterministic analysis (trusted)\n```json\n#{JSON.pretty_generate(trusted_analysis)}\n```"

      if @file_tree.any?
        tree = @file_tree.first(MAX_TREE_PATHS).join("\n")
        parts << "## File tree (first #{MAX_TREE_PATHS} paths)\n#{Untrusted.wrap('file_tree', tree)}"
      end

      if @readme.present?
        parts << "## README\n#{Untrusted.wrap('readme', @readme, max_chars: MAX_README_CHARS)}"
      end

      parts << <<~TASK
        ## Task
        Return a JSON object with any of these keys (omit keys you have nothing new for):
        - "app_description": one sentence describing what the app does
        - "confidence": "high" | "medium" | "low" — your confidence in the detected framework
        - "framework_notes": short note if the framework detection needs clarifying
        - "framework": lowercase framework id, ONLY if the deterministic framework is missing/unknown
        - "port": integer, ONLY if the deterministic port is missing
        - "additional_env_vars": [{"key","required","source","description"}] env vars the scan missed
        - "env_var_suggestions": [{"key","confidence","required","reason"}], confidence is high | possible | review_required
        - "warnings": up to 10 short deployment warnings (missing health check, large image risk, ...)
        Env var keys must be SCREAMING_SNAKE_CASE. Never include secret values.
      TASK

      parts.join("\n\n")
    end

    # Deterministic output minus bulky fields the model doesn't need.
    def trusted_analysis
      @analysis_result.except("dependencies", "ai_enrichment")
    end

    # Validates each top-level key on its own. Arrays keep only valid items.
    def validate_per_key(json)
      accepted = {}
      errors   = []

      SCHEMA["properties"].each do |key, sub|
        next unless json.key?(key)
        value = json[key]

        if sub["type"] == "array" && value.is_a?(Array)
          items = value.first(sub["maxItems"] || value.length)
          good  = items.select do |item|
            item_errors = StructuredOutput.validate(item, sub["items"], "$.#{key}[]")
            errors.concat(item_errors)
            item_errors.empty?
          end
          accepted[key] = good if good.any?
        else
          key_errors = StructuredOutput.validate(value, sub, "$.#{key}")
          if key == "port" && key_errors.empty? && !(1..65_535).cover?(value)
            key_errors << "$.port: out of range"
          end
          errors.concat(key_errors)
          accepted[key] = value if key_errors.empty? && value.present?
        end
      end

      [ accepted, errors ]
    end

    def merge_enrichment(base, enrichment, response:, errors:)
      result = base.deep_dup
      filled = []
      scrub  = ->(s) { Redaction.redact(s.to_s, secrets: @secrets).strip }

      result["app_description"] = scrub.(enrichment["app_description"]) if enrichment["app_description"]
      result["ai_confidence"]   = enrichment["confidence"]              if enrichment["confidence"]
      result["framework_notes"] = scrub.(enrichment["framework_notes"]) if enrichment["framework_notes"]

      # Gap-filling only: deterministic values always win.
      if enrichment["framework"] && (result["framework"].blank? || result["framework"] == "unknown")
        result["framework"] = enrichment["framework"]
        filled << "framework"
      end
      if enrichment["port"] && result["port"].blank?
        result["port"] = enrichment["port"]
        filled << "port"
      end

      if enrichment["warnings"]
        result["warnings"] = ((result["warnings"] || []) + enrichment["warnings"].map(&scrub)).uniq
      end

      if enrichment["additional_env_vars"]
        existing = known_env_keys(result)
        new_vars = enrichment["additional_env_vars"]
          .reject { |v| existing.include?(v["key"]) }
          .uniq   { |v| v["key"] }
          .map do |v|
            {
              "key"          => v["key"],
              "required"     => v["required"] == true,
              "source"       => v["source"].presence || "ai",
              "description"  => v["description"].to_s,
              "ai_suggested" => true
            }
          end
        result["env_vars"] = (result["env_vars"] || []) + new_vars if new_vars.any?
      end

      if enrichment["env_var_suggestions"]
        result["ai_env_var_suggestions"] = enrichment["env_var_suggestions"]
          .map do |v|
            {
              "key"        => v["key"],
              "confidence" => normalize_env_confidence(v["confidence"]),
              "required"   => v["required"] == true,
              "reason"     => v["reason"].to_s.presence
            }
          end
          .uniq { |v| v["key"] }
      end

      result["ai_enrichment"] = {
        "provider"          => response.provider,
        "model"             => response.model,
        "generated_at"      => Time.current.iso8601,
        "filled"            => filled,
        "parsed"            => enrichment,
        "validation_errors" => errors.first(20),
        "raw"               => response.text.to_s.first(Config.settings.max_raw_chars)
      }

      result
    end

    def known_env_keys(result)
      ((result["env_vars"] || []) + (result["detected_env_vars"] || []))
        .map { |v| v["key"] }
        .to_set
    end

    def normalize_env_confidence(value)
      case value.to_s.downcase
      when "high"                   then "high"
      when "review_required", "low" then "review_required"
      else                               "possible"
      end
    end
  end
end
