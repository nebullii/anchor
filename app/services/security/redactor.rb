module Security
  # Scrubs credentials out of free text before it is persisted (deployment
  # logs, error messages), broadcast to the browser, or sent to an LLM.
  #
  #   Security::Redactor.redact(text, secrets: [project_secret_values...])
  #
  # Two layers:
  #   1. Exact values the caller knows are secret (project env vars, the
  #      user's GitHub token, ...). These are removed wherever they appear.
  #   2. Pattern-based detection of well-known credential formats, for
  #      anything we were not told about (tokens echoed by a build, a key
  #      committed to the repo and printed by a failing test, ...).
  #
  # Redaction is deliberately greedy: a false positive costs a slightly
  # less readable log line; a false negative leaks a credential.
  #
  class Redactor
    PLACEHOLDER = "[REDACTED]".freeze

    # Values shorter than this are not redacted by exact match — replacing
    # every "1" or "true" in a log would destroy it without adding safety.
    MIN_SECRET_LENGTH = 6

    # Ordered: the most specific / multi-line patterns run first so that a
    # later, more generic pattern doesn't chop a key block in half.
    PATTERNS = [
      # PEM private keys (RSA, EC, OPENSSH, PKCS#8, encrypted). Also matches
      # the JSON-escaped form ("\n" literal) found in service-account keys.
      [ /-----BEGIN[ A-Z0-9]*PRIVATE KEY-----.*?(?:-----END[ A-Z0-9]*PRIVATE KEY-----|\z)/m,
        "-----BEGIN PRIVATE KEY-----#{PLACEHOLDER}-----END PRIVATE KEY-----" ],

      # "private_key": "..." and "private_key_id": "..." in a service-account JSON.
      [ /("private_key(?:_id)?"\s*:\s*")(?:[^"\\]|\\.)*(")/, "\\1#{PLACEHOLDER}\\2" ],

      # Credentials embedded in URLs: https://user:token@host, redis://:pw@host
      [ %r{\b([a-z][a-z0-9+.\-]*://)[^\s/@:"'<>]*:[^\s/@"'<>]+@}i, "\\1#{PLACEHOLDER}@" ],

      # Authorization headers ("Authorization: token X", "Basic X") and bare
      # bearer tokens anywhere in the text.
      [ /\b(Authorization["']?\s*[:=]\s*["']?(?:Bearer|Basic|token)\s+)[A-Za-z0-9\-._~+\/]+=*/i, "\\1#{PLACEHOLDER}" ],
      [ /\b(Bearer\s+)(?!\[REDACTED\])[A-Za-z0-9\-._~+\/]{8,}=*/i, "\\1#{PLACEHOLDER}" ],

      # GitHub tokens: classic PAT, OAuth, user-to-server, server-to-server,
      # refresh, and fine-grained PATs.
      [ /\bgh[pousr]_[A-Za-z0-9]{20,}\b/, PLACEHOLDER ],
      [ /\bgithub_pat_[A-Za-z0-9_]{20,}\b/, PLACEHOLDER ],

      # Anthropic before OpenAI: "sk-ant-..." also matches the generic sk- rule.
      [ /\bsk-ant-[A-Za-z0-9\-_]{16,}/, PLACEHOLDER ],
      [ /\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9\-_]{16,}/, PLACEHOLDER ],

      # Google API keys and OAuth access / refresh tokens.
      [ /\bAIza[0-9A-Za-z\-_]{35}\b/, PLACEHOLDER ],
      [ /\bya29\.[0-9A-Za-z\-_.]{20,}/, PLACEHOLDER ],
      [ %r{\b1//0[0-9A-Za-z\-_]{30,}}, PLACEHOLDER ],

      # AWS access key IDs, Slack tokens, Stripe live/test secrets, Anchor API tokens.
      [ /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, PLACEHOLDER ],
      [ /\bxox[abpors]-[A-Za-z0-9\-]{10,}/, PLACEHOLDER ],
      [ /\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}/, PLACEHOLDER ],
      [ /\banc_[A-Za-z0-9_\-]{16,}/, PLACEHOLDER ],

      # Generic KEY=value / "key": "value" assignments whose name says secret.
      [ /\b([A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY|CREDENTIALS?)[A-Z0-9_]*)(\s*[=:]\s*)(["']?)[^\s"',;]{4,}\3/i,
        "\\1\\2\\3#{PLACEHOLDER}\\3" ]
    ].freeze

    # Convenience entry point matching the shared contract.
    def self.redact(text, secrets: [])
      new(secrets: secrets).redact(text)
    end

    def initialize(secrets: [])
      @secrets = normalize_secrets(secrets)
    end

    # Returns a redacted copy of +text+. Never mutates the argument and never
    # raises — a redactor that blows up tends to get removed from call sites.
    def redact(text)
      return text if text.nil?

      out = text.to_s.dup
      out = out.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?") unless out.valid_encoding?

      @secrets.each { |secret| out.gsub!(secret, PLACEHOLDER) }
      PATTERNS.each { |pattern, replacement| out.gsub!(pattern, replacement) }
      out
    end

    private

    # Accepts strings, arrays, or hashes (e.g. Secret.to_env_hash); expands
    # each value into the encodings it commonly appears in (raw, URL-encoded,
    # Base64 — e.g. HTTP Basic auth) and sorts longest-first so that a value
    # containing another secret is removed whole.
    def normalize_secrets(secrets)
      values = secrets.is_a?(Hash) ? secrets.values : Array(secrets)
      values
        .flatten
        .compact
        .map(&:to_s)
        .reject { |s| s.strip.length < MIN_SECRET_LENGTH }
        .flat_map { |s| [ s, CGI.escape(s), ERB::Util.url_encode(s), Base64.strict_encode64(s) ] }
        .uniq
        .sort_by { |s| -s.length }
    end
  end
end
