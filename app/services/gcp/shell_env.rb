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
  end
end
