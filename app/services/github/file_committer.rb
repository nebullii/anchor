module Github
  # Commits one or more files to a GitHub repository via the GitHub API.
  #
  # Uses the user's existing Octokit client (authenticated with their GitHub token).
  # Creates new files or updates existing ones in a single commit per file.
  #
  # Usage:
  #   result = Github::FileCommitter.new(
  #     user: current_user,
  #     repo_full_name: "owner/repo",
  #     branch: "main",
  #     files: [{ path: ".github/workflows/deploy.yml", content: "...", message: "Add deploy workflow" }]
  #   ).call
  #
  class FileCommitter
    CommitResult = Struct.new(:success, :committed_files, :error, keyword_init: true) do
      def success? = success
    end

    def initialize(user:, repo_full_name:, branch:, files:)
      @user           = user
      @repo_full_name = repo_full_name
      @branch         = branch
      @files          = files
    end

    def call
      committed = []

      @files.each do |file|
        path    = file[:path] || file["path"]
        content = file[:content] || file["content"]
        message = file[:message] || file["message"] || "Add #{path} via Anchor"

        sha = existing_file_sha(path)

        if sha
          @user.github_client.update_contents(
            @repo_full_name,
            path,
            message,
            sha,
            content,
            branch: @branch
          )
        else
          @user.github_client.create_contents(
            @repo_full_name,
            path,
            message,
            content,
            branch: @branch
          )
        end

        committed << path
      end

      CommitResult.new(success: true, committed_files: committed, error: nil)
    rescue Octokit::Error => e
      CommitResult.new(success: false, committed_files: [], error: e.message)
    rescue => e
      CommitResult.new(success: false, committed_files: [], error: e.message)
    end

    private

    def existing_file_sha(path)
      file = @user.github_client.contents(@repo_full_name, path: path, ref: @branch)
      file[:sha]
    rescue Octokit::NotFound
      nil
    end
  end
end
