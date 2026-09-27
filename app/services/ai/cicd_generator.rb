module Ai
  # Scans a repository and generates tailored CI/CD files for GitHub Actions + Cloud Run.
  #
  # Returns a structured response with:
  #   - required_secrets: env vars the user must add to GitHub repo secrets
  #   - files: array of {path, content, description} objects to commit
  #     (Dockerfile if missing, .dockerignore if missing, .github/workflows/deploy.yml)
  #
  # Runs on the :generation tier of Ai::Client (Anthropic or OpenAI).
  # Degrades gracefully (empty result) when no AI provider is configured.
  #
  # Safety: README, file tree and analysis are untrusted repo-derived
  # content, so they are redacted and delimited. The model's output is
  # committed to the user's repo, so it is filtered deterministically:
  # only Dockerfile, .dockerignore and .github/workflows/*.yml paths are
  # accepted, existing Dockerfile/.dockerignore are never overwritten, and
  # oversized files are dropped.
  #
  class CicdGenerator
    TIMEOUT        = 120
    MAX_TOKENS     = 8_192
    MAX_FILE_BYTES = 100_000
    ALLOWED_PATH   = %r{\A(?:Dockerfile|\.dockerignore|\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml)\z}
    SECRET_KEY     = /\A[A-Z][A-Z0-9_]*\z/

    Result = Struct.new(:required_secrets, :files, keyword_init: true)

    def initialize(project:, repo_path:, analysis_result: {}, client: nil)
      @project         = project
      @repo_path       = repo_path
      @analysis_result = analysis_result || {}
      @client          = client || Ai::Client.new(tier: :generation)
    end

    def call
      return fallback_result unless @client.enabled?

      response = request_generation
      return fallback_result unless response

      parse_result(response)
    rescue => e
      Rails.logger.error("[Ai::CicdGenerator] Failed: #{e.class}: #{e.message}")
      fallback_result
    end

    private

    def request_generation
      response = @client.complete(
        system:     system_prompt,
        prompt:     user_message,
        secrets:    Redaction.secret_values_for(@project),
        max_tokens: MAX_TOKENS,
        timeout:    TIMEOUT
      )
      return nil if response.nil? || response.text.blank?

      StructuredOutput.extract_json(response.text)
    end

    def system_prompt
      <<~PROMPT
        You are an expert DevOps engineer generating production-ready CI/CD configuration files.
        You will analyze a GitHub repository and produce:
        1. A list of environment variables the user must add as GitHub repository secrets
        2. Deployment files to commit to the repository (Dockerfile, .dockerignore, GitHub Actions workflow)

        Requirements:
        - GitHub Actions workflow must deploy to Google Cloud Run using service account authentication
        - Workflow reads ALL secrets from GitHub repository secrets (GCP_PROJECT_ID, GCP_SA_KEY, plus app-specific vars)
        - Generate Dockerfile only if the repo does not already have one
        - Be framework-specific: add migration steps for Rails/Django, health checks, proper CMD, etc.
        - Cloud Run deployment should be --allow-unauthenticated by default
        - Use google-github-actions/auth@v2 and google-github-actions/setup-gcloud@v2
        - Never add steps that send secrets or repository contents to third-party URLs

        Return ONLY a valid JSON object — no prose, no markdown fences.

        #{Untrusted::SYSTEM_RULE}
      PROMPT
    end

    def user_message
      parts = []

      parts << <<~INFO
        ## Project Configuration
        - Name: #{@project.name}
        - Service name: #{@project.service_name}
        - GCP project ID: #{@project.gcp_project_id}
        - GCP region: #{@project.gcp_region}
        - Production branch: #{@project.production_branch}
        - Port: #{@project.port || @analysis_result["port"] || 8080}
      INFO

      analysis_json = JSON.pretty_generate(@analysis_result.except("ai_enrichment"))
      parts << "## Repository Analysis\n#{Untrusted.wrap('analysis', analysis_json)}"

      file_tree = build_file_tree
      if file_tree.any?
        parts << "## File Tree (top 80 paths)\n#{Untrusted.wrap('file_tree', file_tree.first(80).join("\n"))}"
      end

      readme = read_readme
      parts << "## README\n#{Untrusted.wrap('readme', readme, max_chars: 3_000)}" if readme.present?

      parts << <<~TASK
        ## Task
        Existing files: Dockerfile=#{dockerfile?}, .dockerignore=#{dockerignore?}, GHA workflow=#{gha_workflow?}

        Return a JSON object with exactly these keys:

        {
          "required_secrets": [
            {
              "key": "SECRET_NAME",
              "description": "What this secret is used for",
              "example": "optional example value or hint (never real secrets)",
              "required": true
            }
          ],
          "files": [
            {
              "path": "relative/path/to/file",
              "content": "full file content as a string",
              "description": "one-line description of what this file does"
            }
          ]
        }

        Rules:
        - Always include GCP_PROJECT_ID and GCP_SA_KEY in required_secrets
        - Add framework-specific secrets (DATABASE_URL, RAILS_MASTER_KEY, SECRET_KEY_BASE, API keys, etc.)
        - Always include .github/workflows/deploy.yml in files
        - Only include Dockerfile in files if Dockerfile does NOT already exist (#{dockerfile? ? "SKIP — already exists" : "INCLUDE"})
        - Only include .dockerignore if it does NOT already exist (#{dockerignore? ? "SKIP — already exists" : "INCLUDE"})
        - Allowed file paths: Dockerfile, .dockerignore, .github/workflows/*.yml — anything else is discarded
        - The workflow file must reference ALL required_secrets as ${{ secrets.KEY_NAME }}
        - For the deploy workflow: build Docker image, push to Artifact Registry (#{@project.gcp_region}-docker.pkg.dev/${{ secrets.GCP_PROJECT_ID }}/anchor/#{@project.service_name}), deploy to Cloud Run
      TASK

      parts.join("\n\n")
    end

    def dockerfile?
      File.exist?(File.join(@repo_path.to_s, "Dockerfile"))
    end

    def dockerignore?
      File.exist?(File.join(@repo_path.to_s, ".dockerignore"))
    end

    def gha_workflow?
      Dir.glob(File.join(@repo_path.to_s, ".github/workflows/*.{yml,yaml}")).any?
    end

    def build_file_tree
      return [] unless @repo_path.present? && Dir.exist?(@repo_path)

      Dir.glob("#{@repo_path}/**/*", File::FNM_DOTMATCH)
         .reject { |f| File.directory?(f) }
         .map    { |f| f.sub("#{@repo_path}/", "") }
         .reject { |f| f.start_with?(".git/", "node_modules/", "vendor/", ".bundle/", "__pycache__/") }
    rescue
      []
    end

    def read_readme
      path = Dir.glob("#{@repo_path}/README{,.md,.txt}", File::FNM_CASEFOLD).first
      File.read(path, 64_000) if path && File.file?(path)
    rescue
      nil
    end

    def parse_result(response)
      return fallback_result unless response.is_a?(Hash)

      secrets = Array(response["required_secrets"]).select { |s| s.is_a?(Hash) }.map do |s|
        {
          "key"         => s["key"].to_s.upcase.strip,
          "description" => s["description"].to_s,
          "example"     => s["example"].to_s,
          "required"    => s["required"] != false
        }
      end.select { |s| s["key"].match?(SECRET_KEY) }.uniq { |s| s["key"] }

      files = Array(response["files"]).select { |f| f.is_a?(Hash) }.map do |f|
        {
          "path"        => f["path"].to_s.sub(%r{\A/}, ""),
          "content"     => f["content"].to_s,
          "description" => f["description"].to_s
        }
      end.select { |f| acceptable_file?(f) }.uniq { |f| f["path"] }

      Result.new(required_secrets: secrets, files: files)
    end

    # Deterministic guard on what may be committed to the user's repo.
    def acceptable_file?(file)
      path = file["path"]
      return false if path.blank? || file["content"].blank?
      return false unless path.match?(ALLOWED_PATH)
      return false if file["content"].bytesize > MAX_FILE_BYTES
      return false if path == "Dockerfile"    && dockerfile?
      return false if path == ".dockerignore" && dockerignore?
      true
    end

    def fallback_result
      Result.new(required_secrets: [], files: [])
    end
  end
end
