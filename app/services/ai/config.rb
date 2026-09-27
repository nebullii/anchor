module Ai
  # Resolves which LLM provider and model to use.
  #
  # Everything is read from ENV on each call (not memoised) so specs can
  # stub ENV and operators can flip providers without a code change.
  #
  # Tiers let callers ask for "the cheap model" or "the smart model"
  # without hard-coding provider-specific ids:
  #   :fast       — short, high-volume tasks (deployment error explanations)
  #   :analysis   — repository analysis enrichment
  #   :generation — long-form code generation (CI/CD files)
  module Config
    PROVIDERS = %w[anthropic openai].freeze

    DEFAULT_MODELS = {
      "anthropic" => {
        fast:       "claude-haiku-4-5-20251001",
        analysis:   "claude-sonnet-5",
        generation: "claude-sonnet-5"
      },
      "openai" => {
        fast:       "gpt-4o-mini",
        analysis:   "gpt-4o-mini",
        generation: "gpt-4o"
      }
    }.freeze

    API_KEY_ENV = {
      "anthropic" => "ANTHROPIC_API_KEY",
      "openai"    => "OPENAI_API_KEY"
    }.freeze

    module_function

    # Returns "anthropic", "openai", or nil when AI is disabled.
    #
    # An explicit ANCHOR_AI_PROVIDER wins. Otherwise Anthropic is preferred
    # when its key is present, falling back to OpenAI for installs that were
    # configured before Anthropic support existed.
    def provider
      explicit = ENV["ANCHOR_AI_PROVIDER"].to_s.strip.downcase
      return nil if %w[none off disabled].include?(explicit)

      if explicit.present?
        return nil unless PROVIDERS.include?(explicit)
        return api_key_for(explicit).present? ? explicit : nil
      end

      PROVIDERS.find { |p| api_key_for(p).present? }
    end

    def enabled?
      provider.present?
    end

    def api_key_for(provider)
      ENV[API_KEY_ENV.fetch(provider)].presence
    end

    def model_for(provider, tier)
      if tier == :fast && ENV["ANCHOR_AI_MODEL_FAST"].present?
        return ENV["ANCHOR_AI_MODEL_FAST"]
      end
      return ENV["ANCHOR_AI_MODEL"] if ENV["ANCHOR_AI_MODEL"].present?

      DEFAULT_MODELS.fetch(provider).fetch(tier) { DEFAULT_MODELS.fetch(provider).fetch(:analysis) }
    end

    def settings
      Rails.application.config.x.ai
    end
  end
end
