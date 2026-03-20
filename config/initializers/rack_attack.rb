class Rack::Attack
  # ------------------------------------------------------------------ #
  # Cache store                                                          #
  # ------------------------------------------------------------------ #
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
  )

  # ------------------------------------------------------------------ #
  # Throttles                                                            #
  # ------------------------------------------------------------------ #

  # General: 300 requests / 5 min per IP
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets")
  end

  # Auth: 10 login attempts / 20 min per IP (only count POSTs, not OAuth callbacks)
  throttle("auth/ip", limit: 10, period: 20.minutes) do |req|
    req.ip if req.post? && req.path.start_with?("/auth")
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
  # ------------------------------------------------------------------ #
  self.throttled_responder = lambda do |request|
    retry_after = (request.env["rack.attack.match_data"] || {})[:period]
    [
      429,
      {
        "Content-Type"  => "application/json",
        "Retry-After"   => retry_after.to_s
      },
      [ { error: "Too many requests. Please slow down.", retry_after: retry_after }.to_json ]
    ]
  end
end
