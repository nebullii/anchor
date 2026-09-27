# Be sure to restart your server when you modify this file.
#
# Content Security Policy
# ───────────────────────
# Anchor's pages render repository-derived content (analysis results,
# build logs, AI explanations) next to controls that deploy code with the
# user's cloud credentials, so XSS here is high impact. The policy:
#
#   * scripts: same-origin files + a per-request nonce (importmap tags get
#     it automatically) + SHA-256 hashes of the few static inline scripts /
#     handlers in app/views (computed at boot, see AnchorCsp below);
#   * no plugins, no <base> hijacking, no framing (clickjacking);
#   * forms may only post to us and to the OAuth providers we redirect to;
#   * images / fonts / styles limited to the hosts the UI actually uses.
#
# Rollout: CSP_REPORT_ONLY=true switches to Content-Security-Policy-Report-Only;
# CSP_REPORT_URI sends violation reports to a collector.
#
# Frontend follow-up: move the inline <script> blocks in the layout and the
# onclick= handlers into Stimulus controllers; then the hash allowances
# (and 'unsafe-hashes') can be dropped.

module AnchorCsp
  VIEWS_GLOB = "app/views/**/*.html.erb".freeze

  # Static inline <script> bodies (no src=, no ERB, not JSON/importmap).
  INLINE_SCRIPT = %r{<script(?![^>]*\bsrc=)(?![^>]*type="(?:importmap|application/json)")[^>]*>(.*?)</script>}m
  # Static inline event handlers, e.g. onclick="…" (no ERB inside).
  INLINE_HANDLER = /\son[a-z]+="([^"]*)"/

  module_function

  def hash_source(content)
    "'sha256-#{Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(content))}'"
  end

  # [script_hashes, handler_hashes] for every static inline script / handler.
  # Anything containing ERB can't be hashed ahead of time and is skipped —
  # it must use `nonce: true` instead.
  def inline_hashes(root = Rails.root)
    scripts  = []
    handlers = []
    Dir.glob(root.join(VIEWS_GLOB)).each do |file|
      source = File.read(file)
      source.scan(INLINE_SCRIPT) { |(body)| scripts << body unless body.include?("<%") }
      source.scan(INLINE_HANDLER) { |(body)| handlers << body unless body.include?("<%") }
    end
    [ scripts.uniq.map { |s| hash_source(s) }, handlers.uniq.map { |h| hash_source(h) } ]
  end
end

Rails.application.configure do
  script_hashes, handler_hashes = AnchorCsp.inline_hashes

  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri    :self
    policy.object_src  :none
    policy.frame_ancestors :none
    policy.frame_src :none
    policy.manifest_src :self
    policy.worker_src :self

    policy.script_src(
      :self,
      *script_hashes,
      *(handler_hashes.any? ? [ :unsafe_hashes, *handler_hashes ] : [])
    )
    # Turbo's progress bar and Tailwind utilities inject inline styles;
    # style injection is far lower risk than script injection.
    policy.style_src   :self, :unsafe_inline, "https://fonts.googleapis.com"
    policy.font_src    :self, :data, "https://fonts.gstatic.com"
    policy.img_src     :self, :data, "https://avatars.githubusercontent.com", "https://*.googleusercontent.com"
    # Same-origin XHR/fetch and the Action Cable websocket (Turbo Streams).
    policy.connect_src :self
    # OAuth request phase is a form POST that redirects to the provider;
    # Chrome applies form-action to that redirect.
    policy.form_action :self, "https://github.com", "https://accounts.google.com"

    policy.upgrade_insecure_requests true if Rails.env.production?
    policy.report_uri ENV["CSP_REPORT_URI"] if ENV["CSP_REPORT_URI"].present?
  end

  # Nonce per session (Rails default): stable across Turbo Drive visits, which
  # re-use the first page's policy, and never reflected from user input.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.content_security_policy_nonce_auto = true

  config.content_security_policy_report_only = ENV["CSP_REPORT_ONLY"] == "true"

  # Browser features the app never needs. Rails' permissions_policy DSL
  # still emits the legacy Feature-Policy header, so set the modern one here.
  config.action_dispatch.default_headers.merge!(
    "Permissions-Policy" => "camera=(), microphone=(), geolocation=(), usb=(), payment=(), gyroscope=(), interest-cohort=()"
  )
end
