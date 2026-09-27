# Receives GitHub webhook deliveries and turns pushes to a project's
# production branch into deployments.
#
# Security properties:
#   * Every delivery that can have a side effect is authenticated with the
#     project's own HMAC secret (X-Hub-Signature-256). The shared global
#     secret is only accepted when ANCHOR_ALLOW_GLOBAL_WEBHOOK_SECRET=true.
#   * When the webhook URL carries ?project=<slug>, the signature is checked
#     before anything inside the payload is looked at or queried by.
#     Nothing is written to the database until a signature has matched.
#   * Deliveries are deduplicated on X-GitHub-Delivery, so redeliveries
#     don't trigger duplicate deployments.
#   * Malformed input gets a 4xx, never a 500.
#
# NOTE: read the slug via request.query_parameters, not `params`, so that
# controller code never works from values parsed out of an unverified body.
#
class WebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token

  # GitHub caps payloads at 25 MB, but push payloads we act on are tiny.
  MAX_PAYLOAD_BYTES = 5.megabytes

  # Upper bound on projects checked per legacy (URL without ?project=) delivery.
  MAX_LEGACY_CANDIDATES = 20

  GLOBAL_SECRET_FLAG = "ANCHOR_ALLOW_GLOBAL_WEBHOOK_SECRET".freeze

  def github
    return head(:content_too_large) if request.content_length.to_i > MAX_PAYLOAD_BYTES

    event = request.headers["X-GitHub-Event"].to_s

    # ping (sent when the hook is created) and events we don't act on are
    # acknowledged without touching the body or the database.
    return render(json: { ok: true, event: "ping" }) if event == "ping"
    return head(:accepted) unless event == "push"

    body = request.raw_post.to_s
    return head(:content_too_large) if body.bytesize > MAX_PAYLOAD_BYTES

    slug = request.query_parameters["project"].presence

    if slug
      # Preferred: project named in the URL → verify the signature before
      # looking at anything inside the payload.
      project = Project.find_by(slug: slug.to_s)
      return head(:unauthorized) unless project && signed_for?(project, body)

      data = parse_payload(body)
      return head(:bad_request) unless data.is_a?(Hash)
      # The payload must be about this project's repository.
      return head(:unauthorized) unless repo_full_name(data) == project.repository&.full_name

      projects = [ project ]
    else
      # Legacy URL (/webhooks/github): the repository name in the body tells
      # us whose secret to check. Nothing is written until one matches.
      data = parse_payload(body)
      return head(:bad_request) unless data.is_a?(Hash)

      projects = legacy_candidates(data).select { |p| signed_for?(p, body) }
      return head(:unauthorized) if projects.empty?
    end

    handle_push(projects, data, event)
  end

  private

  # ── Authentication ───────────────────────────────────────────────────── #

  def legacy_candidates(data)
    Project.joins(:repository)
           .where(repositories: { full_name: repo_full_name(data) })
           .order(:id)
           .limit(MAX_LEGACY_CANDIDATES)
  end

  def signed_for?(project, body)
    signature = request.headers["X-Hub-Signature-256"].to_s
    return true if Security::GithubWebhookSignature.valid?(body, project.webhook_secret, signature)

    global_secret_allowed? &&
      Security::GithubWebhookSignature.valid?(body, ENV["GITHUB_WEBHOOK_SECRET"], signature)
  end

  # The shared global secret lets anyone who knows it trigger deploys for
  # EVERY project, so it's off unless explicitly enabled during migration.
  def global_secret_allowed?
    ENV[GLOBAL_SECRET_FLAG] == "true"
  end

  # ── Push handling ────────────────────────────────────────────────────── #

  def handle_push(projects, data, event)
    ref = data["ref"].to_s
    # Tags and branch deletions never deploy.
    return head(:ok) unless ref.start_with?("refs/heads/")
    return head(:ok) if data["deleted"] == true

    branch  = ref.delete_prefix("refs/heads/")
    project = projects.find { |p| p.auto_deploy? && p.production_branch == branch }
    return head(:ok) unless project

    deployment = nil
    duplicate  = false

    Project.transaction do
      # Idempotency: the first delivery wins. Claimed in the same transaction
      # as the deployment, so a failure lets GitHub's redelivery retry.
      delivery_id = request.headers["X-GitHub-Delivery"].presence
      if delivery_id && !WebhookDelivery.claim(delivery_id: delivery_id, event: event, project_id: project.id)
        duplicate = true
        next
      end

      next if project.has_active_deployment?

      head_commit = data["head_commit"].is_a?(Hash) ? data["head_commit"] : {}
      deployment = project.deployments.create!(
        status:         "queued",
        triggered_by:   "webhook",
        branch:         branch,
        commit_sha:     head_commit["id"].to_s.first(64).presence,
        commit_message: head_commit["message"]&.to_s&.truncate(200),
        commit_author:  head_commit.dig("author", "name")&.to_s&.first(255)
      )
    end

    return render(json: { ok: true, duplicate: true }) if duplicate

    DeploymentJob.perform_later(deployment.id) if deployment
    head :ok
  end

  # ── Parsing ──────────────────────────────────────────────────────────── #

  # GitHub sends either application/json or form-encoded `payload=<json>`.
  def parse_payload(body)
    json = if request.media_type == "application/x-www-form-urlencoded"
      Rack::Utils.parse_query(body)["payload"].to_s
    else
      body
    end
    JSON.parse(json, max_nesting: 64)
  rescue JSON::ParserError, EncodingError, ArgumentError
    nil
  end

  def repo_full_name(data)
    repository = data["repository"]
    repository.is_a?(Hash) ? repository["full_name"].to_s : ""
  end
end
