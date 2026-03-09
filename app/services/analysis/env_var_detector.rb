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
      "DATABASE_URL"           => { source: "database",        required: true  },
      "REDIS_URL"              => { source: "redis",           required: false },
      "SECRET_KEY_BASE"        => { source: "rails",           required: true  },
      "RAILS_MASTER_KEY"       => { source: "rails",           required: true  },
      "OPENAI_API_KEY"         => { source: "openai",          required: true  },
      "ANTHROPIC_API_KEY"      => { source: "anthropic",       required: true  },
      "STRIPE_SECRET_KEY"      => { source: "stripe",          required: true  },
      "STRIPE_PUBLISHABLE_KEY" => { source: "stripe",          required: false },
      "SENDGRID_API_KEY"       => { source: "sendgrid",        required: true  },
      "MAILGUN_API_KEY"        => { source: "mailgun",         required: true  },
      "AWS_ACCESS_KEY_ID"      => { source: "aws",             required: true  },
      "AWS_SECRET_ACCESS_KEY"  => { source: "aws",             required: true  },
      "GOOGLE_API_KEY"         => { source: "google",          required: true  },
      "GOOGLE_CLIENT_ID"       => { source: "google-oauth",    required: true  },
      "GOOGLE_CLIENT_SECRET"   => { source: "google-oauth",    required: true  },
      "GITHUB_TOKEN"           => { source: "github",          required: true  },
      "TWILIO_ACCOUNT_SID"     => { source: "twilio",          required: true  },
      "TWILIO_AUTH_TOKEN"      => { source: "twilio",          required: true  },
      "SENTRY_DSN"             => { source: "sentry",          required: false },
      "DJANGO_SECRET_KEY"      => { source: "django",          required: true  },
      "DJANGO_SETTINGS_MODULE" => { source: "django",          required: false },
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
          "required" => known.fetch(:required, false)
        }
      end.sort_by { |v| [v["required"] ? 0 : 1, v["key"]] }
    end
  end
end
