require "net/http"
require "uri"

module Deployments
  # Probes a freshly deployed (not yet promoted) revision over HTTP.
  #
  # One call to #probe = one HTTP request. Retry/backoff is driven by
  # HealthCheckJob, which re-enqueues itself with `set(wait:)` so no Sidekiq
  # thread ever sleeps waiting for a cold start.
  #
  # A probe is healthy when:
  #   - the request completes (no timeout / connection error), and
  #   - the status is < 500 and not 429, and
  #   - the body is not a platform/proxy error page (e.g. Google Frontend's
  #     "Error 404 (Not Found)!!1" page served while a revision URL is not
  #     routable yet). An app's own 404 on "/" still counts as healthy: the
  #     process is up and answering.
  #
  #   result = Deployments::HealthChecker.new("https://rev---svc.a.run.app", path: "/up").probe
  #   result.healthy?  # => true
  #   result.detail    # => "HTTP 200"
  #
  class HealthChecker
    Result = Struct.new(:healthy, :status, :detail, keyword_init: true) do
      def healthy? = healthy
    end

    # Retry schedule. Defaults give 8 probes over ~2.5 minutes, which covers
    # Rails/Django cold starts on Cloud Run without making a bad release wait
    # long to be declared failed. Both are overridable via ENV.
    DEFAULT_ATTEMPTS       = 8
    DEFAULT_BUDGET_SECONDS = 150
    # Seconds to wait before attempt N+1 (last value repeats).
    BACKOFF_SCHEDULE       = [ 5, 10, 15, 20, 25, 30 ].freeze

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    BODY_SNIFF_BYTES = 4_096

    # Bodies that mean "the platform answered, not your app".
    PROXY_ERROR_PATTERNS = [
      /Error \d{3} \([^)]*\)!!1/,                                   # Google Frontend error page
      /The requested URL .* was not found on this server/i,        # GFE 404 while revision/tag not routable
      /Service Unavailable.*Google/im,
      /no available server/i,                                       # Traefik / generic LB
      /upstream connect error or disconnect\/reset before headers/i # Envoy
    ].freeze

    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
      Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, OpenSSL::SSL::SSLError, EOFError, IOError
    ].freeze

    def self.max_attempts
      Integer(ENV.fetch("HEALTH_CHECK_ATTEMPTS", DEFAULT_ATTEMPTS))
    end

    def self.budget_seconds
      Integer(ENV.fetch("HEALTH_CHECK_BUDGET_SECONDS", DEFAULT_BUDGET_SECONDS))
    end

    # Delay (seconds) to wait after a failed attempt number `attempt` (1-based).
    def self.backoff_for(attempt)
      BACKOFF_SCHEDULE[attempt - 1] || BACKOFF_SCHEDULE.last
    end

    def initialize(base_url, path: "/", headers: {})
      @uri     = build_uri(base_url, path)
      @headers = headers || {}
    end

    attr_reader :uri

    def probe
      response = request
      status   = response.code.to_i
      body     = response.body.to_s[0, BODY_SNIFF_BYTES]

      if status >= 500
        Result.new(healthy: false, status: status, detail: "HTTP #{status}")
      elsif status == 429
        Result.new(healthy: false, status: status, detail: "HTTP 429 (no instance available)")
      elsif proxy_error_page?(body)
        Result.new(healthy: false, status: status, detail: "HTTP #{status} from platform proxy, not the app")
      else
        Result.new(healthy: true, status: status, detail: "HTTP #{status}")
      end
    rescue *NETWORK_ERRORS => e
      Result.new(healthy: false, status: nil, detail: "#{e.class}: #{e.message}".truncate(200))
    end

    private

    def request
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = "Anchor-HealthCheck/1.0"
      @headers.each { |k, v| req[k] = v }
      http.request(req)
    end

    def proxy_error_page?(body)
      PROXY_ERROR_PATTERNS.any? { |re| body.match?(re) }
    end

    def build_uri(base_url, path)
      base = URI.parse(base_url.to_s)
      raise ArgumentError, "health check URL must be http(s): #{base_url.inspect}" unless base.is_a?(URI::HTTP)

      path = path.presence || "/"
      path = "/#{path}" unless path.start_with?("/")
      path, query = path.split("?", 2)
      base.path  = base.path.to_s.chomp("/") + path
      base.query = query if query.present?
      base
    end
  end
end
