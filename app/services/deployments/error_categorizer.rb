module Deployments
  # Categorizes deployment failure messages into machine-readable categories
  # so the UI can show actionable guidance without always needing AI.
  class ErrorCategorizer
    CATEGORIES = {
      "auth_error"          => /permission denied|insufficient.+permission|access denied|PERMISSION_DENIED|IAM/i,
      "quota_exceeded"      => /quota exceeded|QUOTA_EXCEEDED|rate limit/i,
      "image_not_found"     => /image.*not found|manifest unknown|not found.*image/i,
      "build_timeout"       => /build.*timeout|exceeded.*deadline|DEADLINE_EXCEEDED/i,
      "dockerfile_error"    => /dockerfile.*error|failed to build|build.*failed|RUN.*returned.*exit code/i,
      "oom_killed"          => /out of memory|memory limit|OOM|SIGKILL/i,
      "port_mismatch"       => /port.*not.*listen|container.*port|EXPOSE/i,
      "missing_env_var"     => /undefined.*ENV|KeyError.*not found|Missing.*variable/i,
      "database_error"      => /PG::|ActiveRecord::.*Error|could not connect.*postgres|database.*connection/i,
      "git_clone_error"     => /git clone.*failed|authentication.*failed.*clone|repository.*not found/i,
      "repo_too_large"      => /too large to deploy|maximum allowed size/i,
      "gcp_not_configured"  => /GCP service account not configured/i,
      "concurrent_deploy"   => /concurrent deployment/i
    }.freeze

    def self.categorize(error_message)
      return "unknown" if error_message.blank?

      CATEGORIES.each do |category, pattern|
        return category if error_message.match?(pattern)
      end

      "unknown"
    end

    def self.user_hint(category)
      HINTS.fetch(category, "Check the deployment logs for more details.")
    end

    HINTS = {
      "auth_error"         => "The GCP service account may be missing required IAM roles. " \
                               "Ensure it has Cloud Run Admin, Cloud Build Editor, and Artifact Registry Writer roles.",
      "quota_exceeded"     => "A GCP quota limit was reached. Check your project quotas in the Google Cloud Console.",
      "image_not_found"    => "The container image could not be found in Artifact Registry. " \
                               "Check that the build completed successfully.",
      "build_timeout"      => "Cloud Build timed out (30 min limit). Consider optimizing your Dockerfile " \
                               "with multi-stage builds or a smaller base image.",
      "dockerfile_error"   => "The Dockerfile failed to build. Review the build logs for the failing RUN instruction.",
      "oom_killed"         => "The container ran out of memory. Increase the memory limit in your project settings.",
      "port_mismatch"      => "The app is not listening on the expected port. " \
                               "Ensure your app binds to the PORT environment variable.",
      "missing_env_var"    => "A required environment variable is missing. Add it in the project Secrets section.",
      "database_error"     => "The app could not connect to the database. Check your DATABASE_URL secret.",
      "git_clone_error"    => "Could not clone the repository. Ensure the GitHub token has repo access.",
      "repo_too_large"     => "The repository exceeds the 500 MB size limit.",
      "gcp_not_configured" => "No GCP service account key configured. Go to Settings → GCP Credentials to add one.",
      "concurrent_deploy"  => "Another deployment is already in progress for this project."
    }.freeze
  end
end
