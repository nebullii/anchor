class User < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Encryption                                                           #
  # ------------------------------------------------------------------ #
  attr_encrypted :github_token,
                 key: proc { ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key) }

  attr_encrypted :google_access_token,
                 key: proc { ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key) }

  attr_encrypted :google_refresh_token,
                 key: proc { ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key) }

  attr_encrypted :gcp_service_account_key,
                 key: proc { ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key) }

  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  has_many :repositories, dependent: :destroy
  has_many :projects,     dependent: :destroy
  has_many :deployments,  through: :projects

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :github_id,    presence: true, uniqueness: true
  validates :github_login, presence: true, uniqueness: true

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :with_active_projects, -> {
    joins(:projects).where(projects: { status: "active" }).distinct
  }

  # ------------------------------------------------------------------ #
  # Instance helpers                                                     #
  # ------------------------------------------------------------------ #

  # Returns an authenticated Octokit client using the stored token.
  def github_client
    @github_client ||= Octokit::Client.new(access_token: github_token)
  end

  # Build a User from an OmniAuth hash returned by omniauth-github.
  def self.from_omniauth(auth)
    find_or_initialize_by(github_id: auth.uid.to_s).tap do |user|
      user.github_login = auth.info.nickname
      user.github_token = auth.credentials.token
      user.name         = auth.info.name
      user.email        = auth.info.email
      user.avatar_url   = auth.info.image
      user.save!
    end
  end

  def display_name
    name.presence || github_login
  end

  # True when the user has configured a GCP service account key.
  def google_connected?
    gcp_service_account_key.present?
  end

  # Returns the parsed service account JSON, or nil.
  def gcp_credentials
    return nil unless gcp_service_account_key.present?
    JSON.parse(gcp_service_account_key)
  rescue JSON::ParserError
    nil
  end

  # The service account email extracted from the key, used for display.
  def gcp_service_account_email
    gcp_credentials&.dig("client_email")
  end

  # The GCP project ID extracted from the key.
  def gcp_project_from_key
    gcp_credentials&.dig("project_id")
  end

  # Writes the service account key to a temp file and yields the file path.
  # Cleans up the file after the block completes.
  def with_gcp_credentials_file
    raise "GCP service account not configured" unless gcp_service_account_key.present?
    file = Tempfile.new([ "gcp-sa-#{id}", ".json" ])
    file.write(gcp_service_account_key)
    file.flush
    yield file.path
  ensure
    file&.close
    file&.unlink
  end
end
