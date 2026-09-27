module Security
  # Guardrail for files produced by an LLM before Anchor commits them to a
  # user's repository with the user's GitHub token.
  #
  # The model's input includes repository content (README, file tree), which
  # an attacker can control — so its output must be treated as untrusted.
  # A prompt-injected response could otherwise overwrite application code or
  # add a workflow that exfiltrates the repo's Actions secrets.
  #
  #   violations = Security::GeneratedFilePolicy.violations(files)
  #   raise ... if violations.any?
  #
  # `files` is an array of hashes with "path"/"content" (string or symbol keys).
  #
  module GeneratedFilePolicy
    # Exactly the files the CI/CD setup feature is meant to write.
    ALLOWED_PATHS = [
      "Dockerfile",
      ".dockerignore",
      %r{\A\.github/workflows/[A-Za-z0-9_\-]+\.ya?ml\z}
    ].freeze

    MAX_FILES         = 5
    MAX_CONTENT_BYTES = 64.kilobytes

    # Workflow constructs that are dangerous in generated CI config.
    WORKFLOW_RULES = [
      [ /\bpull_request_target\b/,
        "uses pull_request_target (runs untrusted PR code with repository secrets)" ],
      [ /\$\{\{\s*toJSON\(\s*secrets\s*\)\s*\}\}/i,
        "serialises the entire secrets context" ],
      [ /\$\{\{\s*github\.event\.(?:issue|pull_request|comment|review|head_commit)\.[^}]*\}\}/,
        "interpolates attacker-controlled event data into the workflow (script injection)" ],
      [ /\b(?:curl|wget)\b[^\n]*\|\s*(?:ba|z)?sh\b/,
        "pipes a remote script into a shell" ],
      [ /\bpermissions:\s*write-all\b/,
        "requests write-all token permissions" ]
    ].freeze

    module_function

    # Returns an array of human-readable violation strings (empty = OK).
    def violations(files)
      files  = Array(files)
      errors = []
      errors << "too many files (#{files.size} > #{MAX_FILES})" if files.size > MAX_FILES

      files.each do |file|
        path    = (file["path"] || file[:path]).to_s
        content = (file["content"] || file[:content]).to_s

        unless allowed_path?(path)
          errors << "#{path.inspect}: path is not an allowed CI/CD file"
          next
        end

        errors << "#{path}: content too large" if content.bytesize > MAX_CONTENT_BYTES
        next unless path.start_with?(".github/workflows/")

        WORKFLOW_RULES.each do |pattern, message|
          errors << "#{path}: #{message}" if content.match?(pattern)
        end
      end

      errors
    end

    def allowed_path?(path)
      return false if path.empty? || path.include?("..") || path.start_with?("/") || path.include?("\\")

      ALLOWED_PATHS.any? { |rule| rule.is_a?(Regexp) ? rule.match?(path) : rule == path }
    end
  end
end
