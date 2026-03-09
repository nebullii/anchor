module Analysis
  # Scans repository source files for environment variable access patterns and
  # returns a list of detected variables annotated with source and required flag.
  class EnvVarDetector
    PATTERNS = {
      ruby: [
        /ENV\[["']([A-Z][A-Z0-9_]{2,})["']\]/,           # ENV["FOO"]
        /ENV\.fetch\(["']([A-Z][A-Z0-9_]{2,})["']/,       # ENV.fetch("FOO")
      ],
      python: [
        /os\.environ\[["']([A-Z][A-Z0-9_]{2,})["']\]/,         # os.environ["FOO"]
        /os\.environ\.get\(["']([A-Z][A-Z0-9_]{2,})["']/,      # os.environ.get("FOO")
        /os\.getenv\(["']([A-Z][A-Z0-9_]{2,})["']/,            # os.getenv("FOO")
      ],
      javascript: [
        /process\.env\.([A-Z][A-Z0-9_]{2,})/,            # process.env.FOO
        /process\.env\[["']([A-Z][A-Z0-9_]{2,})["']\]/,  # process.env["FOO"]
      ]
    }.freeze

    # Well-known vars: we annotate these with source/required even if not found by scan,
    # as long as a related dependency is present (handled by DatabaseDetector / caller).
    KNOWN_VARS = {
      "DATABASE_URL"           => { source: "database",     required: true,  url: nil,                                                    hint: "Connection string for your database (e.g. postgresql://user:pass@host/db)" },
      "REDIS_URL"              => { source: "redis",        required: false, url: nil,                                                    hint: "Redis connection string (e.g. redis://localhost:6379/0)" },
      "SECRET_KEY_BASE"        => { source: "rails",        required: true,  url: nil,                                                    hint: "Generate with: rails secret" },
      "RAILS_MASTER_KEY"       => { source: "rails",        required: true,  url: nil,                                                    hint: "Found in config/master.key — do not commit this file" },
      "OPENAI_API_KEY"         => { source: "openai",       required: true,  url: "https://platform.openai.com/api-keys",                 hint: "Create at platform.openai.com/api-keys" },
      "ANTHROPIC_API_KEY"      => { source: "anthropic",    required: true,  url: "https://console.anthropic.com/settings/keys",          hint: "Create at console.anthropic.com/settings/keys" },
      "STRIPE_SECRET_KEY"      => { source: "stripe",       required: true,  url: "https://dashboard.stripe.com/apikeys",                 hint: "Get from Stripe Dashboard → Developers → API keys" },
      "STRIPE_PUBLISHABLE_KEY" => { source: "stripe",       required: false, url: "https://dashboard.stripe.com/apikeys",                 hint: "Get from Stripe Dashboard → Developers → API keys" },
      "SENDGRID_API_KEY"       => { source: "sendgrid",     required: true,  url: "https://app.sendgrid.com/settings/api_keys",           hint: "Create at SendGrid → Settings → API Keys" },
      "MAILGUN_API_KEY"        => { source: "mailgun",      required: true,  url: "https://app.mailgun.com/app/account/security/api_keys", hint: "Get from Mailgun → Account → Security → API Keys" },
      "AWS_ACCESS_KEY_ID"      => { source: "aws",          required: true,  url: "https://console.aws.amazon.com/iam/home#/security_credentials", hint: "Create in AWS IAM → Security Credentials" },
      "AWS_SECRET_ACCESS_KEY"  => { source: "aws",          required: true,  url: "https://console.aws.amazon.com/iam/home#/security_credentials", hint: "Created alongside AWS_ACCESS_KEY_ID" },
      "GOOGLE_API_KEY"         => { source: "google",       required: true,  url: "https://console.cloud.google.com/apis/credentials",    hint: "Create at GCP Console → APIs & Services → Credentials" },
      "GOOGLE_CLIENT_ID"       => { source: "google-oauth", required: true,  url: "https://console.cloud.google.com/apis/credentials",    hint: "OAuth 2.0 Client ID from GCP Console → Credentials" },
      "GOOGLE_CLIENT_SECRET"   => { source: "google-oauth", required: true,  url: "https://console.cloud.google.com/apis/credentials",    hint: "OAuth 2.0 Client Secret from GCP Console → Credentials" },
      "GITHUB_TOKEN"           => { source: "github",       required: true,  url: "https://github.com/settings/tokens",                   hint: "Create a Personal Access Token at GitHub → Settings → Developer settings" },
      "TWILIO_ACCOUNT_SID"     => { source: "twilio",       required: true,  url: "https://console.twilio.com/",                          hint: "Found on your Twilio Console dashboard" },
      "TWILIO_AUTH_TOKEN"      => { source: "twilio",       required: true,  url: "https://console.twilio.com/",                          hint: "Found on your Twilio Console dashboard" },
      "SENTRY_DSN"             => { source: "sentry",       required: false, url: "https://sentry.io/settings/",                          hint: "Get from Sentry → Project Settings → Client Keys (DSN)" },
      "DJANGO_SECRET_KEY"      => { source: "django",       required: true,  url: nil,                                                    hint: "Generate with: python -c \"from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())\"" },
      "DJANGO_SETTINGS_MODULE" => { source: "django",       required: false, url: nil,                                                    hint: "Python dotted path to your settings file (e.g. myapp.settings.production)" },
    }.freeze

    SKIP_KEYS = %w[PORT HOST RACK_ENV RAILS_ENV NODE_ENV PYTHONUNBUFFERED].freeze

    def initialize(repo_path, framework)
      @repo_path = repo_path
      @framework = framework
    end

    def call
      keys = scan_source_files
      deduplicate_and_annotate(keys)
    end

    private

    def scan_source_files
      found = Set.new
      source_files.each do |file|
        content = File.read(file, encoding: "utf-8", invalid: :replace, undef: :replace)
        patterns_for(file).each do |pattern|
          content.scan(pattern) { |m| found << m.first }
        end
      rescue => e
        Rails.logger.warn("EnvVarDetector: could not read #{file}: #{e.message}")
      end
      found.to_a
    end

    def source_files
      exts = case @framework
             when "rails"         then "rb,erb,yml,yaml"
             when "python", "fastapi", "flask", "django" then "py,env.example,.env.example"
             when "node", "nextjs" then "js,ts,jsx,tsx,mjs"
             else "rb,py,js,ts,jsx,tsx"
             end

      Dir.glob(File.join(@repo_path, "**", "*.{#{exts}}"))
         .reject { |f| f =~ %r{/(node_modules|\.git|vendor|\.bundle|__pycache__|spec|test)/} }
         .first(300)
    end

    def patterns_for(file)
      case File.extname(file)
      when ".rb", ".erb"       then PATTERNS[:ruby]
      when ".py"               then PATTERNS[:python]
      when ".js", ".ts", ".jsx", ".tsx", ".mjs" then PATTERNS[:javascript]
      else []
      end
    end

    def deduplicate_and_annotate(keys)
      filtered = keys
        .reject { |k| SKIP_KEYS.include?(k) }
        .reject { |k| k.length < 4 }
        .uniq
        .sort

      filtered.map do |key|
        known = KNOWN_VARS[key] || {}
        {
          "key"      => key,
          "source"   => known[:source] || "source code",
          "required" => known.fetch(:required, false),
          "url"      => known[:url],
          "hint"     => known[:hint]
        }
      end.sort_by { |v| [v["required"] ? 0 : 1, v["key"]] }
    end
  end
end
