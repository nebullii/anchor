# AI / LLM configuration.
#
# Provider and model selection is read from ENV at call time (see Ai::Config)
# so it can be changed without a deploy and stubbed in specs. The values
# below are process-wide tunables that rarely change.
#
#   ANCHOR_AI_PROVIDER    anthropic | openai | none   (default: first provider with a key)
#   ANCHOR_AI_MODEL       overrides the model for every tier
#   ANCHOR_AI_MODEL_FAST  overrides only the cheap "fast" tier (error explanations)
#   ANTHROPIC_API_KEY     key for the Anthropic Messages API
#   OPENAI_API_KEY        key for the OpenAI Chat Completions API
#
# When no key is configured every AI feature is a silent no-op.
Rails.application.config.x.ai = ActiveSupport::OrderedOptions.new.merge!(
  open_timeout:  10,
  # Seconds to wait before the single retry on 429/5xx/connection failure.
  retry_delay:   Rails.env.test? ? 0 : 1.5,
  # Hard ceiling on characters of untrusted content (logs, READMEs, file
  # trees) placed in a single prompt. Keeps cost bounded and limits the
  # surface for prompt injection.
  max_untrusted_chars: 12_000,
  # Raw model output kept for audit/debugging is truncated to this size.
  max_raw_chars: 20_000
)
