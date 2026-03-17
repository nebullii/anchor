module Ai
  # Enriches deterministic analysis results with AI-powered insights.
  #
  # Calls the OpenAI Chat Completions API (gpt-4o-mini for speed/cost) with
  # a structured prompt that includes the deterministic analysis and asks the
  # model to:
  #   - Confirm / correct the detected framework and runtime
  #   - Identify additional environment variables that should be set
  #   - Flag deployment warnings (e.g. missing health check, large image risk)
  #   - Suggest a concise description of what the app does
  #
  # Degrades gracefully when OPENAI_API_KEY is not set — the original
  # analysis result is returned unchanged.
  #
  class RepositoryAnalyzer
    API_URL = "https://api.openai.com/v1/chat/completions".freeze
    MODEL   = "gpt-4o-mini".freeze
    TIMEOUT = 30

    def initialize(analysis_result, file_tree: [], readme: nil)
      @analysis_result = analysis_result
      @file_tree       = file_tree
      @readme          = readme
    end

    # Returns an enriched copy of analysis_result (Hash) or the original if
    # the API is unavailable / not configured.
    def call
      return @analysis_result unless api_key.present?

      response = request_enrichment
      return @analysis_result unless response

      merge_enrichment(@analysis_result, response)
    rescue => e
      Rails.logger.warn("[Ai::RepositoryAnalyzer] Enrichment skipped: #{e.message}")
      @analysis_result
    end

    private

    def api_key
      ENV["OPENAI_API_KEY"]
    end

    def request_enrichment
      conn = Faraday.new(url: API_URL) do |f|
        f.options.timeout      = TIMEOUT
        f.options.open_timeout = 10
        f.request  :json
        f.response :json
      end

      response = conn.post do |req|
        req.headers["Authorization"] = "Bearer #{api_key}"
        req.body = {
          model:      MODEL,
          max_tokens: 1024,
          messages:   [
            { role: "system", content: system_prompt },
            { role: "user",   content: user_message  }
          ]
        }
      end

      return nil unless response.success?

      text = response.body.dig("choices", 0, "message", "content").to_s
      parse_json_block(text)
    end

    def system_prompt
      <<~PROMPT
        You are an expert DevOps engineer helping analyze application repositories for cloud deployment.
        You will receive a deterministic analysis of a repository and must return enriched insights in JSON.
        Be concise. Return ONLY a JSON object — no prose, no markdown, no code fences.
      PROMPT
    end

    def user_message
      parts = []
      parts << "## Deterministic Analysis\n```json\n#{JSON.pretty_generate(@analysis_result)}\n```"

      if @file_tree.any?
        parts << "## File Tree (top 60 paths)\n#{@file_tree.first(60).join("\n")}"
      end

      if @readme.present?
        parts << "## README (first 2000 chars)\n#{@readme.to_s.first(2_000)}"
      end

      parts << <<~PROMPT
        ## Task
        Return a JSON object with these keys (all optional — omit keys you have no new info for):
        - "app_description": one-sentence description of what this app does
        - "additional_env_vars": array of {"key","required","source","description"} objects for env vars the deterministic scan missed
        - "env_var_suggestions": array of {"key","confidence","required","reason"} where confidence is high | possible | review_required
        - "warnings": array of additional deployment warning strings
        - "confidence": "high" | "medium" | "low" — your confidence in the framework detection
        - "framework_notes": brief string if you'd correct or clarify the detected framework
      PROMPT

      parts.join("\n\n")
    end

    def parse_json_block(text)
      JSON.parse(text)
    rescue JSON::ParserError
      # Try extracting a JSON object if the model wrapped it in prose
      match = text.match(/\{[\s\S]*\}/)
      return nil unless match
      JSON.parse(match[0])
    rescue
      nil
    end

    def merge_enrichment(base, enrichment)
      result = base.deep_dup

      result["app_description"]  = enrichment["app_description"]  if enrichment["app_description"].present?
      result["ai_confidence"]    = enrichment["confidence"]        if enrichment["confidence"].present?
      result["framework_notes"]  = enrichment["framework_notes"]   if enrichment["framework_notes"].present?

      if enrichment["warnings"].is_a?(Array) && enrichment["warnings"].any?
        result["warnings"] = ((result["warnings"] || []) + enrichment["warnings"]).uniq
      end

      if enrichment["additional_env_vars"].is_a?(Array) && enrichment["additional_env_vars"].any?
        existing_keys = (
          (result["env_vars"] || []) + (result["detected_env_vars"] || [])
        ).map { |v| v["key"] }.to_set
        new_vars = enrichment["additional_env_vars"].select do |v|
          v["key"].present? && !existing_keys.include?(v["key"])
        end
        result["env_vars"] = (result["env_vars"] || []) + new_vars
      end

      if enrichment["env_var_suggestions"].is_a?(Array) && enrichment["env_var_suggestions"].any?
        result["ai_env_var_suggestions"] = enrichment["env_var_suggestions"]
          .select { |v| v["key"].present? }
          .map do |v|
            {
              "key"        => v["key"].to_s.upcase,
              "confidence" => normalize_env_confidence(v["confidence"]),
              "required"   => v["required"] == true,
              "reason"     => v["reason"].to_s.presence
            }
          end
          .uniq { |v| v["key"] }
      end

      result
    end

    def normalize_env_confidence(value)
      case value.to_s.downcase
      when "high"             then "high"
      when "review_required", "low" then "review_required"
      else                         "possible"
      end
    end
  end
end
