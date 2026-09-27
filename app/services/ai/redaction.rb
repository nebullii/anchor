module Ai
  # Scrubs secrets from any text headed to an LLM provider.
  #
  # Delegates to Security::Redactor (owned by AppSec) when it is loaded.
  # Until then — or if it raises — a conservative built-in fallback runs
  # instead. The fallback intentionally over-redacts: a garbled log line
  # costs nothing, a leaked credential costs a lot.
  module Redaction
    MASK = "[REDACTED]".freeze

    # Secrets shorter than this are not substring-replaced: masking every
    # "1" or "abc" in a log would destroy it without adding protection.
    MIN_SECRET_LENGTH = 4

    PATTERNS = [
      # https://user:token@host (git clone URLs, x-access-token, basic auth)
      [ %r{(https?://)[^/\s:@]+:[^@\s/]+@}i,                     '\1' + MASK + "@" ],
      [ /(Bearer\s+)[A-Za-z0-9\-._~+\/]{8,}=*/i,                  '\1' + MASK ],
      [ /\b(gh[pousr]_[A-Za-z0-9]{20,})\b/,                        MASK ],
      [ /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,                        MASK ],
      [ /\bsk-ant-[A-Za-z0-9\-_]{10,}\b/,                          MASK ],
      [ /\bsk-(?:proj-)?[A-Za-z0-9\-_]{16,}\b/,                    MASK ],
      [ /\banc_[A-Za-z0-9]{16,}\b/,                                MASK ],
      [ /\b(AKIA|ASIA)[A-Z0-9]{16}\b/,                             MASK ],
      [ /\bAIza[0-9A-Za-z\-_]{35}\b/,                              MASK ],
      [ /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/,                       MASK ],
      [ /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/, MASK ],
      [ /("private_key"\s*:\s*")[^"]+(")/,                         '\1' + MASK + '\2' ],
      # KEY=value / KEY: value where the name looks sensitive
      [ /\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*)(\s*[=:]\s*)(["']?)[^\s"']{4,}\3/i,
       '\1\2' + MASK ],
      # Credentials embedded in database URLs: postgres://user:pass@host
      [ %r{\b((?:postgres(?:ql)?|mysql2?|redis|rediss|mongodb(?:\+srv)?|amqps?)://[^:/\s]+:)[^@\s]+@}i, '\1' + MASK + "@" ]
    ].freeze

    module_function

    def redact(text, secrets: [])
      return "" if text.nil?
      text = text.to_s

      if security_redactor?
        begin
          return Security::Redactor.redact(text, secrets: secrets)
        rescue => e
          Rails.logger.warn("[Ai::Redaction] Security::Redactor failed (#{e.class}); using fallback")
        end
      end

      fallback_redact(text, secrets: secrets)
    end

    def fallback_redact(text, secrets: [])
      out = text.dup

      # Longest first so a secret that contains another is fully masked.
      Array(secrets).compact.map(&:to_s)
        .select { |s| s.length >= MIN_SECRET_LENGTH }
        .uniq.sort_by { |s| -s.length }
        .each { |secret| out = out.gsub(secret, MASK) }

      PATTERNS.each { |pattern, replacement| out = out.gsub(pattern, replacement) }
      out
    end

    # Plaintext secret values for a project. Decryption failures (e.g. a
    # rotated ENCRYPTION_KEY) must not break AI features, so they are
    # skipped — the pattern-based fallback still applies.
    def secret_values_for(project)
      return [] unless project.respond_to?(:secrets)

      values = project.secrets.filter_map do |secret|
        secret.value
      rescue StandardError
        nil
      end

      # The owner's GitHub token can appear in clone output.
      token = begin
        project.try(:user).try(:github_token)
      rescue StandardError
        nil
      end
      values << token if token.present?
      values
    rescue StandardError
      []
    end

    def security_redactor?
      Object.const_defined?("Security::Redactor")
    rescue NameError, LoadError
      false
    end
  end
end
