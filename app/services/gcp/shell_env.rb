module Gcp
  # Builds a safe environment hash for shelling out to gcloud,
  # ensuring the binary is always findable regardless of the calling process's PATH.
  module ShellEnv
    GCLOUD_PATH = begin
      dir = `which gcloud 2>/dev/null`.strip
      dir.present? ? File.dirname(dir) : "/opt/homebrew/bin"
    end.freeze

    def self.with_key(key_path)
      {
        "PATH"                                   => "#{GCLOUD_PATH}:#{ENV.fetch('PATH', '/usr/local/bin:/usr/bin:/bin')}",
        "GOOGLE_APPLICATION_CREDENTIALS"         => key_path,
        "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" => key_path,
        "CLOUDSDK_CORE_DISABLE_PROMPTS"          => "1"
      }
    end

    def self.with_token(token)
      {
        "PATH"                          => "#{GCLOUD_PATH}:#{ENV.fetch('PATH', '/usr/local/bin:/usr/bin:/bin')}",
        "CLOUDSDK_AUTH_ACCESS_TOKEN"    => token,
        "CLOUDSDK_CORE_DISABLE_PROMPTS" => "1"
      }
    end

    # Yields the gcloud environment for a user, preferring OAuth (refreshing
    # the access token only when it is about to expire) and falling back to a
    # service account key written to a short-lived temp file.
    def self.for_user(user)
      if user.google_oauth_connected?
        yield with_token(user.fresh_google_access_token)
      else
        user.with_gcp_credentials_file { |key_path| yield with_key(key_path) }
      end
    end
  end
end
