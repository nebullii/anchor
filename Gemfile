source "https://rubygems.org"

gem "dotenv-rails", groups: [:development, :test]

gem "rails", "~> 8.1.2"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails"
gem "bootsnap", require: false
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Background jobs
gem "sidekiq", "~> 8.0"
gem "redis", "~> 5.0"

# GitHub OAuth + API
gem "omniauth-github", "~> 2.0"
gem "omniauth-google-oauth2", "~> 1.0"
gem "omniauth-rails_csrf_protection"
gem "octokit", "~> 10.0"

# Encryption for tokens and secrets
gem "attr_encrypted", "~> 4.0"

# Google Cloud APIs
gem "google-apis-run_v2",          "~> 0.110"
gem "google-apis-cloudbuild_v1",   "~> 0.79"
gem "googleauth",                  "~> 1.0"

# HTTP client (GitHub API calls, webhooks)
gem "faraday", "~> 2.0"

# Rate limiting
gem "rack-attack", "~> 6.7"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails"
  gem "faker"
end

group :test do
  gem "shoulda-matchers", "~> 7.0"
  gem "webmock", "~> 3.0"
end

group :development do
  gem "web-console"
end
