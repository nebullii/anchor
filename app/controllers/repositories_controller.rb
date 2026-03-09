class RepositoriesController < ApplicationController
  def index
    @repositories = current_user.repositories.ordered
  end

  def sync
    repos = current_user.github_client.repos(current_user.github_login, per_page: 100)
    repos.each { |repo| Repository.sync_from_github(current_user, repo) }
    redirect_to repositories_path, notice: "#{repos.count} repositories synced."
  rescue Octokit::Error => e
    redirect_to repositories_path, alert: "GitHub sync failed: #{e.message}"
  end
end
