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

  def google_connected?
    google_refresh_token.present?
  end

  def gcp_configured?
    gcp_service_account_key.present?
  end

  def store_gcp_service_account(project_id, service_account_email, key_json)
    update!(
      default_gcp_project_id:     project_id,
      gcp_service_account_email:  service_account_email,
      gcp_service_account_key:    key_json
    )
  end

  # Returns a fresh access token, refreshing via Google if expired.
  def fresh_google_access_token
    return google_access_token if google_token_expires_at&.future?
    refresh_google_access_token
  end

  def connect_google(auth)
    update!(
      google_email:             auth.info.email,
      google_access_token:      auth.credentials.token,
      google_refresh_token:     auth.credentials.refresh_token || google_refresh_token,
      google_token_expires_at:  Time.at(auth.credentials.expires_at)
    )
  end

  private

  def refresh_google_access_token
    response = Faraday.post("https://oauth2.googleapis.com/token") do |req|
      req.body = {
        client_id:     ENV["GOOGLE_CLIENT_ID"] || Rails.application.credentials.dig(:google, :client_id),
        client_secret: ENV["GOOGLE_CLIENT_SECRET"] || Rails.application.credentials.dig(:google, :client_secret),
        refresh_token: google_refresh_token,
        grant_type:    "refresh_token"
      }
    end

    data = JSON.parse(response.body)
    update!(
      google_access_token:     data["access_token"],
      google_token_expires_at: Time.current + data["expires_in"].to_i.seconds
    )
    data["access_token"]
  end
end
