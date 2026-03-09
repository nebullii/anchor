class Repository < ApplicationRecord
  # ------------------------------------------------------------------ #
  # Associations                                                         #
  # ------------------------------------------------------------------ #
  belongs_to :user
  has_many   :projects, dependent: :nullify

  # ------------------------------------------------------------------ #
  # Validations                                                          #
  # ------------------------------------------------------------------ #
  validates :github_id,   presence: true, uniqueness: true
  validates :name,        presence: true
  validates :full_name,   presence: true, uniqueness: true,
                          format: { with: /\A[\w.\-]+\/[\w.\-]+\z/,
                                    message: "must be in owner/repo format" }
  validates :owner_login, presence: true
  validates :clone_url,   presence: true
  validates :html_url,    presence: true

  # ------------------------------------------------------------------ #
  # Scopes                                                               #
  # ------------------------------------------------------------------ #
  scope :recently_synced,  -> { where("last_synced_at > ?", 1.hour.ago) }
  scope :stale,            -> { where("last_synced_at < ? OR last_synced_at IS NULL", 1.hour.ago) }
  scope :public_repos,     -> { where(private: false) }
  scope :private_repos,    -> { where(private: true) }
  scope :ordered,          -> { order(full_name: :asc) }

  # ------------------------------------------------------------------ #
  # Instance helpers                                                     #
  # ------------------------------------------------------------------ #

  # Build or update a Repository from a GitHub API response object.
  # `repo` is an Octokit::Repository (Sawyer::Resource).
  def self.sync_from_github(user, repo)
    record = find_or_initialize_by(github_id: repo.id.to_s)
    record.assign_attributes(
      user:           user,
      name:           repo.name,
      full_name:      repo.full_name,
      owner_login:    repo.owner.login,
      description:    repo.description,
      default_branch: repo.default_branch || "main",
      clone_url:      repo.clone_url,
      html_url:       repo.html_url,
      private:        repo.private,
      language:       repo.language,
      size_kb:        repo.size,
      last_synced_at: Time.current
    )
    record.save!
    record
  end

  def stale?
    last_synced_at.nil? || last_synced_at < 1.hour.ago
  end

  # Authenticated clone URL with the user's GitHub token embedded.
  def authenticated_clone_url
    uri = URI.parse(clone_url)
    uri.user     = user.github_login
    uri.password = user.github_token
    uri.to_s
  end
end
