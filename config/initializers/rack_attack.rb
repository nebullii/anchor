class Rack::Attack
  # ------------------------------------------------------------------ #
  # Cache store                                                          #
  # Redis in development / production so counters are shared by every   #
  # web instance. Tests use an in-process store and start disabled so    #
  # request specs don't trip limits or share counters through Redis;     #
  # spec/requests/rack_attack_spec.rb enables it explicitly.            #
  # ------------------------------------------------------------------ #
  if Rails.env.test?
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled     = false
  else
    Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
    )
  end

  # ------------------------------------------------------------------ #
  # Paths excluded from the general per-IP throttle.                     #
  #   * health probes — the platform's prober shares a few IPs and must  #
  #     never be told to back off;                                       #
  #   * GitHub webhooks — every customer's deliveries come from GitHub's #
  #     small IP pool, so a per-IP limit would let one busy repo block   #
  #     deploys for everyone. They're authenticated by HMAC instead.     #
  #   * /api/v1 — throttled per token and per IP below with API limits.  #
  # ------------------------------------------------------------------ #
  UNTHROTTLED_PATHS = %w[/up /healthz /readyz /webhooks/github].freeze

  def self.unthrottled_path?(req)
    UNTHROTTLED_PATHS.include?(req.path) || req.path.start_with?("/assets/")
  end

  def self.api_path?(req)
    req.path == "/api/v1" || req.path.start_with?("/api/v1/")
  end

  # Throttle key for an API client: SHA-256 of its bearer token, so raw
  # tokens are never written to Redis. Matches ApiToken#token_digest.
  def self.api_token_digest(req)
    header = req.get_header("HTTP_AUTHORIZATION").to_s
    token  = header[/\ABearer\s+(\S+)\z/i, 1]
    Digest::SHA256.hexdigest(token) if token.present?
  end

  # ------------------------------------------------------------------ #
  # Throttles                                                            #
  # ------------------------------------------------------------------ #

  # General: 300 requests / 5 min per IP (browser traffic).
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless unthrottled_path?(req) || api_path?(req)
  end

  # Auth: 10 login attempts / 20 min per IP (only count POSTs, not OAuth callbacks)
  throttle("auth/ip", limit: 10, period: 20.minutes) do |req|
    req.ip if req.post? && req.path.start_with?("/auth")
  end

  # API, per token: 600 requests / 5 min (≈ 2 req/s sustained — enough for
  # an agent tailing logs). Keyed by token digest, not user, so one leaked
  # or runaway token can't exhaust the owner's other tokens.
  throttle("api/token", limit: 600, period: 5.minutes) do |req|
    api_token_digest(req) if api_path?(req)
  end

  # API, per IP: backstop so rotating made-up tokens doesn't bypass limits.
  throttle("api/ip", limit: 1200, period: 5.minutes) do |req|
    req.ip if api_path?(req)
  end

  # API deploy / rollback: 30 / hour per token.
  throttle("api/deploy/token", limit: 30, period: 1.hour) do |req|
    if req.post? && req.path.match?(%r{\A/api/v1/projects/[^/]+/(deployments|rollback)\z})
      api_token_digest(req)
    end
  end

  # Deploy: 20 deploys / hour per authenticated user
  throttle("deploy/user", limit: 20, period: 1.hour) do |req|
    if req.path.match?(%r{\A/projects/[^/]+/deploy\z}) && req.post?
      req.session[:user_id]
    end
  end

  # Analyze: 30 analyzes / hour per authenticated user
  throttle("analyze/user", limit: 30, period: 1.hour) do |req|
    if req.path.match?(%r{\A/projects/[^/]+/analyze\z}) && req.post?
      req.session[:user_id]
    end
  end

  # Repository sync: 10 syncs / 10 min per user
  throttle("repo_sync/user", limit: 10, period: 10.minutes) do |req|
    if req.path == "/repositories/sync" && req.post?
      req.session[:user_id]
    end
  end

  # ------------------------------------------------------------------ #
  # Response for throttled requests                                      #
  # API clients get the /api/v1 error envelope.                          #
  # ------------------------------------------------------------------ #
  self.throttled_responder = lambda do |request|
    retry_after = (request.env["rack.attack.match_data"] || {})[:period]
    body =
      if Rack::Attack.api_path?(request)
        { error: { code: "rate_limited", message: "Too many requests. Retry after #{retry_after}s." } }
      else
        { error: "Too many requests. Please slow down.", retry_after: retry_after }
      end

    [
      429,
      {
        "Content-Type" => "application/json",
        "Retry-After"  => retry_after.to_s
      },
      [ body.to_json ]
    ]
  end
end
