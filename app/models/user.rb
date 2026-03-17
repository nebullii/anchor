class User < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Encryption                                                           #
  # ------------------------------------------------------------------ #
  ENCRYPTION_KEY = proc {
    raw = ENV["ENCRYPTION_KEY"] || Rails.application.credentials.dig(:encryption, :key)
    Digest::SHA256.digest(raw.to_s)[0, 32]
  }

  attr_encrypted :github_token,          key: ENCRYPTION_KEY, algorithm: "aes-256-cbc"
  attr_encrypted :google_access_token,   key: ENCRYPTION_KEY, algorithm: "aes-256-cbc"
  attr_encrypted :google_refresh_token,  key: ENCRYPTION_KEY, algorithm: "aes-256-cbc"
  attr_encrypted :gcp_service_account_key, key: ENCRYPTION_KEY, algorithm: "aes-256-cbc"

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

  # True when the user has connected Google Cloud via OAuth OR service account key.
  def google_connected?
    google_access_token.present? || gcp_service_account_key.present?
  end

  # True only when connected via OAuth.
  def google_oauth_connected?
    google_access_token.present?
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

  # Returns a fresh access token, refreshing via Google if expired or expiring soon.
  def fresh_google_access_token
    return google_access_token if google_token_expires_at.present? && google_token_expires_at > 5.minutes.from_now
    fresh_google_token!
  end

  # Returns a fresh OAuth access token, refreshing it first if expired.
  # Raises if no OAuth tokens are stored.
  def fresh_google_token!
    raise "Google account not connected via OAuth" unless google_refresh_token.present?

    if google_token_expires_at.nil? || google_token_expires_at <= 5.minutes.from_now
      refresh_google_token!
    end

    google_access_token
  end

  # Exchanges the stored refresh token for a new access token.
  def refresh_google_token!
    require "signet/oauth_2/client"

    client = Signet::OAuth2::Client.new(
      token_credential_uri: "https://oauth2.googleapis.com/token",
      client_id:     ENV["GOOGLE_CLIENT_ID"]     || Rails.application.credentials.dig(:google, :client_id),
      client_secret: ENV["GOOGLE_CLIENT_SECRET"] || Rails.application.credentials.dig(:google, :client_secret),
      refresh_token: google_refresh_token
    )
    client.refresh!

    update!(
      google_access_token:     client.access_token,
      google_token_expires_at: Time.at(client.expires_at)
    )
  end

  # The email address of the connected Google account (OAuth), or the
  # service account email extracted from the JSON key.
  def connected_google_email
    google_email.presence || gcp_credentials&.dig("client_email")
  end

  # Returns the parsed service account JSON, or nil.
  def gcp_credentials
    return nil unless gcp_service_account_key.present?
    JSON.parse(gcp_service_account_key)
  rescue JSON::ParserError
    nil
  end

  # The GCP project ID extracted from the service account key.
  def gcp_project_from_key
    gcp_credentials&.dig("project_id")
  end

  # ------------------------------------------------------------------ #
  # Deployment quotas                                                    #
  # ------------------------------------------------------------------ #
  DAILY_DEPLOY_LIMIT   = 20
  MONTHLY_DEPLOY_LIMIT = 200

  def within_deploy_quota?
    reset_quota_if_needed!
    deployments_today < DAILY_DEPLOY_LIMIT &&
      deployments_this_month < MONTHLY_DEPLOY_LIMIT
  end

  def increment_deploy_quota!
    reset_quota_if_needed!
    increment!(:deployments_today)
    increment!(:deployments_this_month)
  end

  # ------------------------------------------------------------------ #
  # GCP credentials                                                      #
  # ------------------------------------------------------------------ #

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

  private

  def reset_quota_if_needed!
    now = Time.current
    return unless quota_reset_at.nil? || now > quota_reset_at

    reset_at = now.beginning_of_day + 1.day
    update_columns(
      deployments_today:      0,
      deployments_this_month: now.day == 1 ? 0 : deployments_this_month,
      quota_reset_at:         reset_at
    )
  end
end
