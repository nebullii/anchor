module Ai
  # Generates a human-friendly explanation for a failed deployment.
  #
  # Sends the raw error message and recent deployment logs to OpenAI and
  # returns a short, actionable explanation of what went wrong and how to
  # fix it.
  #
  # Degrades gracefully when OPENAI_API_KEY is not set.
  #
  class ErrorExplainer
    API_URL   = "https://api.openai.com/v1/chat/completions".freeze
    MODEL     = "gpt-4o-mini".freeze
    TIMEOUT   = 20
    MAX_CHARS = 8_000  # keep prompt cost low

    def initialize(deployment)
      @deployment = deployment
    end

    # Returns an explanation string, or nil if the API is unavailable.
    def call
      return nil unless api_key.present?

      response = request_explanation
      response&.strip.presence
    rescue => e
      Rails.logger.warn("[Ai::ErrorExplainer] Skipped: #{e.message}")
      nil
    end

    private

    def api_key
      ENV["OPENAI_API_KEY"]
    end

    def request_explanation
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
          max_tokens: 512,
          messages:   [
            { role: "system", content: system_prompt },
            { role: "user",   content: user_message  }
          ]
        }
      end

      return nil unless response.success?

      response.body.dig("choices", 0, "message", "content")
    end

    def system_prompt
      <<~PROMPT
        You are a deployment expert helping developers fix failed cloud deployments.
        Given deployment logs and an error message, provide a concise (2-4 sentences) explanation
        of what went wrong and the most likely fix. Be specific — mention file names, environment
        variables, or commands when relevant. Do not use markdown or bullet points.
      PROMPT
    end

    def user_message
      project   = @deployment.project
      framework = project.framework.presence || "unknown"
      logs      = recent_logs

      <<~MSG
        Framework: #{framework}
        GCP Project: #{project.gcp_project_id}
        Branch: #{@deployment.branch}

        Error:
        #{@deployment.error_message.to_s.first(1_000)}

        Recent deployment logs (last #{MAX_CHARS} chars):
        #{logs}
      MSG
    end

    def recent_logs
      @deployment
        .deployment_logs
        .order(logged_at: :desc)
        .limit(100)
        .pluck(:message)
        .reverse
        .join("\n")
        .last(MAX_CHARS)
    end
  end
end
