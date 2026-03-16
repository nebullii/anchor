module Ai
  # Scans a repository and generates tailored CI/CD files for GitHub Actions + Cloud Run.
  #
  # Returns a structured response with:
  #   - required_secrets: env vars the user must add to GitHub repo secrets
  #   - files: array of {path, content, description} objects to commit
  #     (Dockerfile if missing, .dockerignore if missing, .github/workflows/deploy.yml)
  #
  # Uses claude-sonnet-4-6 for high-quality code generation.
  # Degrades gracefully if ANTHROPIC_API_KEY is not set.
  #
  class CicdGenerator
    API_URL = "https://api.anthropic.com/v1/messages".freeze
    MODEL   = "claude-sonnet-4-6".freeze
    TIMEOUT = 90

    Result = Struct.new(:required_secrets, :files, keyword_init: true)

    def initialize(project:, repo_path:, analysis_result: {})
      @project         = project
      @repo_path       = repo_path
      @analysis_result = analysis_result || {}
    end

    def call
      return fallback_result unless api_key.present?

      response = request_generation
      return fallback_result unless response

      parse_result(response)
    rescue => e
      Rails.logger.error("[Ai::CicdGenerator] Failed: #{e.message}")
      fallback_result
    end

    private

    def api_key
      ENV["ANTHROPIC_API_KEY"]
    end

    def request_generation
      conn = Faraday.new(url: API_URL) do |f|
        f.options.timeout      = TIMEOUT
        f.options.open_timeout = 15
        f.request  :json
        f.response :json
      end

      response = conn.post do |req|
        req.headers["x-api-key"]        = api_key
        req.headers["anthropic-version"] = "2023-06-01"
        req.body = {
          model:      MODEL,
          max_tokens: 8192,
          system:     system_prompt,
          messages:   [{ role: "user", content: user_message }]
        }
      end

      return nil unless response.success?

      text = response.body.dig("content", 0, "text").to_s
      parse_json_block(text)
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

        Return ONLY a valid JSON object — no prose, no markdown fences.
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

      parts << "## Repository Analysis\n```json\n#{JSON.pretty_generate(@analysis_result)}\n```"

      file_tree = build_file_tree
      if file_tree.any?
        parts << "## File Tree (top 80 paths)\n#{file_tree.first(80).join("\n")}"
      end

      readme = read_readme
      parts << "## README\n#{readme.first(3_000)}" if readme.present?

      has_dockerfile    = File.exist?(File.join(@repo_path, "Dockerfile"))
      has_dockerignore  = File.exist?(File.join(@repo_path, ".dockerignore"))
      has_gha_workflow  = Dir.glob(File.join(@repo_path, ".github/workflows/*.yml")).any? ||
                          Dir.glob(File.join(@repo_path, ".github/workflows/*.yaml")).any?

      parts << <<~TASK
        ## Task
        Existing files: Dockerfile=#{has_dockerfile}, .dockerignore=#{has_dockerignore}, GHA workflow=#{has_gha_workflow}

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
        - Only include Dockerfile in files if Dockerfile does NOT already exist (#{has_dockerfile ? "SKIP — already exists" : "INCLUDE"})
        - Only include .dockerignore if it does NOT already exist (#{has_dockerignore ? "SKIP — already exists" : "INCLUDE"})
        - The workflow file must reference ALL required_secrets as ${{ secrets.KEY_NAME }}
        - For the deploy workflow: build Docker image, push to Artifact Registry (#{@project.gcp_region}-docker.pkg.dev/${{ "{{" }} secrets.GCP_PROJECT_ID {{ "}}" }}/anchor/#{@project.service_name}), deploy to Cloud Run
      TASK

      parts.join("\n\n")
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
      File.read(path) if path && File.exist?(path)
    rescue
      nil
    end

    def parse_json_block(text)
      JSON.parse(text)
    rescue JSON::ParserError
      match = text.match(/\{[\s\S]*\}/)
      return nil unless match
      JSON.parse(match[0])
    rescue
      nil
    end

    def parse_result(response)
      secrets = (response["required_secrets"] || []).map do |s|
        {
          "key"         => s["key"].to_s.upcase.strip,
          "description" => s["description"].to_s,
          "example"     => s["example"].to_s,
          "required"    => s["required"] != false
        }
      end.reject { |s| s["key"].blank? }

      files = (response["files"] || []).map do |f|
        {
          "path"        => f["path"].to_s.sub(%r{\A/}, ""),
          "content"     => f["content"].to_s,
          "description" => f["description"].to_s
        }
      end.reject { |f| f["path"].blank? || f["content"].blank? }

      Result.new(required_secrets: secrets, files: files)
    end

    def fallback_result
      Result.new(required_secrets: [], files: [])
    end
  end
end
