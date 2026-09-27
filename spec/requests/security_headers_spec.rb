require "rails_helper"

RSpec.describe "Security headers", type: :request do
  def csp
    response.headers["Content-Security-Policy"].to_s
  end

  def directive(name)
    csp.split(";").map(&:strip).find { |d| d.start_with?("#{name} ") }.to_s
  end

  before { get "/" }

  it "sends a restrictive Content-Security-Policy" do
    expect(response).to have_http_status(:ok)
    expect(directive("default-src")).to eq("default-src 'self'")
    expect(directive("object-src")).to eq("object-src 'none'")
    expect(directive("base-uri")).to eq("base-uri 'self'")
    expect(directive("frame-ancestors")).to eq("frame-ancestors 'none'")
    expect(directive("form-action")).to include("'self'", "https://github.com", "https://accounts.google.com")
  end

  it "never allows unsafe-inline or unsafe-eval scripts" do
    expect(directive("script-src")).not_to include("'unsafe-inline'")
    expect(directive("script-src")).not_to include("'unsafe-eval'")
    expect(directive("script-src")).not_to include("https:")
  end

  it "allows every inline script on the page via its nonce or hash" do
    nonce  = directive("script-src")[/'nonce-([^']+)'/, 1]
    doc    = Nokogiri::HTML(response.body)
    inline = doc.css("script:not([src])")
    expect(inline).not_to be_empty

    inline.each do |script|
      allowed =
        (nonce && script["nonce"] == nonce) ||
        directive("script-src").include?(AnchorCsp.hash_source(script.text))
      expect(allowed).to be(true), "inline script not covered by CSP:\n#{script.to_html.first(200)}"
    end
  end

  it "hashes static inline event handlers found in views" do
    _, handler_hashes = AnchorCsp.inline_hashes
    handler_hashes.each { |h| expect(directive("script-src")).to include(h) }
    expect(directive("script-src")).to include("'unsafe-hashes'") if handler_hashes.any?
  end

  it "sends a Permissions-Policy that disables unused features" do
    expect(response.headers["Permissions-Policy"]).to include("camera=()", "microphone=()", "geolocation=()")
  end

  it "keeps Rails' default hardening headers" do
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
    expect(response.headers["Referrer-Policy"]).to eq("strict-origin-when-cross-origin")
  end
end
