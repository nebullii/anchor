class WebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token

  def github
    payload_body = request.body.read

    unless valid_signature?(payload_body)
      head :unauthorized and return
    end

    unless request.headers["X-GitHub-Event"] == "push"
      head :ok and return
    end

    data           = JSON.parse(payload_body)
    repo_full_name = data.dig("repository", "full_name")
    pushed_branch  = data["ref"].to_s.sub("refs/heads/", "")

    project = Project
      .joins(:repository)
      .where(repositories: { full_name: repo_full_name }, auto_deploy: true)
      .find_by("projects.production_branch = ?", pushed_branch)

    head :ok and return unless project
    head :ok and return if project.has_active_deployment?

    deployment = project.deployments.create!(
      status:         "queued",
      triggered_by:   "webhook",
      branch:         pushed_branch,
      commit_sha:     data.dig("head_commit", "id"),
      commit_message: data.dig("head_commit", "message")&.truncate(200),
      commit_author:  data.dig("head_commit", "author", "name")
    )
    DeploymentJob.perform_later(deployment.id)

    head :ok
  end

  private

  def valid_signature?(body)
    secret = ENV["GITHUB_WEBHOOK_SECRET"].to_s
    return false if secret.blank?

    expected = "sha256=#{OpenSSL::HMAC.hexdigest('sha256', secret, body)}"
    received = request.headers["X-Hub-Signature-256"].to_s
    ActiveSupport::SecurityUtils.secure_compare(expected, received)
  end
end
