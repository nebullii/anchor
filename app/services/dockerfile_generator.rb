class DockerfileGenerator
  def initialize(repo_path, detection)
    @repo_path = repo_path
    @detection = detection
  end

  # Writes a Dockerfile to `repo_path`. No-ops if one already exists.
  # Returns the path to the Dockerfile.
  def call
    dockerfile_path = File.join(@repo_path, "Dockerfile")
    return dockerfile_path if File.exist?(dockerfile_path)

    content = template_for(@detection.framework)
    raise "No Dockerfile template for framework: #{@detection.framework}" if content.nil?

    File.write(dockerfile_path, content)
    dockerfile_path
  end

  private

  def template_for(framework)
    case framework
    when "rails"   then rails_template
    when "node"    then node_template
    when "nextjs"  then nextjs_template
    when "fastapi" then fastapi_template
    when "flask"   then flask_template
    when "django"  then django_template
    when "python"  then python_template
    when "static"  then static_template
    when "go"      then go_template
    when "bun"     then bun_template
    when "elixir"  then elixir_template
    else                nil   # "docker" framework already has a Dockerfile
    end
  end

  # ------------------------------------------------------------------ #
  # Templates                                                            #
  # ------------------------------------------------------------------ #

  def rails_template
    ruby_version = @detection.metadata&.dig("ruby_version") || "3.2"
    has_lock     = @detection.metadata&.dig("bundler_lock")
    copy_lock    = has_lock ? "COPY Gemfile Gemfile.lock ./" : "COPY Gemfile ./"
    port         = @detection.port

    <<~DOCKERFILE
      # syntax=docker/dockerfile:1

      # ── Build stage ───────────────────────────────────────────────────────────
      FROM ruby:#{ruby_version}-slim AS build

      RUN apt-get update -qq && \\
          apt-get install --no-install-recommends -y \\
            build-essential git libpq-dev libyaml-dev pkg-config curl nodejs && \\
          rm -rf /var/lib/apt/lists /var/cache/apt/archives

      ENV RAILS_ENV=production \\
          BUNDLE_DEPLOYMENT=1 \\
          BUNDLE_PATH=/usr/local/bundle \\
          BUNDLE_WITHOUT=development:test

      WORKDIR /app

      #{copy_lock}
      RUN bundle install --jobs 4 --retry 3 && \\
          rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache

      COPY . .

      # Precompile assets — ignore errors for API-only apps.
      RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile 2>/dev/null || true

      # ── Final stage ───────────────────────────────────────────────────────────
      FROM ruby:#{ruby_version}-slim

      RUN apt-get update -qq && \\
          apt-get install --no-install-recommends -y libpq5 libjemalloc2 && \\
          rm -rf /var/lib/apt/lists /var/cache/apt/archives

      # Non-root user for security
      RUN groupadd --system --gid 1000 rails && \\
          useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
      USER 1000:1000

      ENV RAILS_ENV=production \\
          BUNDLE_DEPLOYMENT=1 \\
          BUNDLE_PATH=/usr/local/bundle \\
          BUNDLE_WITHOUT=development:test \\
          RAILS_LOG_TO_STDOUT=true \\
          RAILS_SERVE_STATIC_FILES=true

      WORKDIR /app

      COPY --chown=rails:rails --from=build /usr/local/bundle /usr/local/bundle
      COPY --chown=rails:rails --from=build /app /app

      EXPOSE #{port}

      HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \\
        CMD curl -f http://localhost:#{port}/up || exit 1

      CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
    DOCKERFILE
  end

  def node_template
    node_version = @detection.metadata&.dig("node_version") || "20"
    has_lock     = @detection.metadata&.dig("has_lock_file")
    start_script = @detection.metadata&.dig("start_script")
    build_script = @detection.metadata&.dig("build_script")
    main_file    = @detection.metadata&.dig("main") || "index.js"
    port         = @detection.port

    install_cmd = if has_lock
      # Prefer lock-file-respecting install
      "npm ci --omit=dev"
    else
      "npm install --omit=dev"
    end

    start_cmd = if start_script
      '["npm", "start"]'
    else
      %(["node", "#{main_file}"])
    end

    build_step = build_script ? "RUN npm run build" : ""

    <<~DOCKERFILE
      FROM node:#{node_version}-alpine

      WORKDIR /app

      COPY package*.json ./
      RUN #{install_cmd}

      COPY . .
      #{build_step}

      ENV NODE_ENV=production
      EXPOSE #{port}

      CMD #{start_cmd}
    DOCKERFILE
  end

  def python_template
    entry_point  = @detection.metadata&.dig("entry_point") || "app.py"
    has_procfile = @detection.metadata&.dig("has_procfile")
    port         = @detection.port

    # Prefer gunicorn for production if it's likely a web app.
    start_cmd = if has_procfile
      '["sh", "-c", "$(head -n1 Procfile | cut -d: -f2-)"]'
    elsif entry_point == "manage.py"
      # Django
      %(["gunicorn", "--bind", "0.0.0.0:#{port}", "--workers", "2", "wsgi:application"])
    else
      %(["python", "#{entry_point}"])
    end

    requirements_step = if @detection.metadata&.dig("has_requirements")
      "COPY requirements.txt .\nRUN pip install --no-cache-dir -r requirements.txt"
    else
      "COPY pyproject.toml .\nRUN pip install --no-cache-dir ."
    end

    <<~DOCKERFILE
      FROM python:3.11-slim

      WORKDIR /app

      #{requirements_step}

      COPY . .

      ENV PYTHONUNBUFFERED=1
      EXPOSE #{port}

      CMD #{start_cmd}
    DOCKERFILE
  end

  def nextjs_template
    node_version = @detection.metadata&.dig("node_version") || "20"
    build_script = @detection.metadata&.dig("build_script")
    has_lock     = @detection.metadata&.dig("has_lock_file")
    port         = @detection.port

    install_cmd = has_lock ? "npm ci" : "npm install"

    <<~DOCKERFILE
      FROM node:#{node_version}-alpine AS deps
      WORKDIR /app
      COPY package*.json ./
      RUN #{install_cmd}

      FROM node:#{node_version}-alpine AS builder
      WORKDIR /app
      COPY --from=deps /app/node_modules ./node_modules
      COPY . .
      RUN npm run build

      FROM node:#{node_version}-alpine AS runner
      WORKDIR /app
      ENV NODE_ENV=production
      COPY --from=builder /app/public ./public
      COPY --from=builder /app/.next/standalone ./
      COPY --from=builder /app/.next/static ./.next/static

      EXPOSE #{port}
      CMD ["node", "server.js"]
    DOCKERFILE
  end

  def fastapi_template
    entry    = @detection.metadata&.dig("entry_point") || "main.py"
    app_module = File.basename(entry, ".py")
    port     = @detection.port

    <<~DOCKERFILE
      FROM python:3.11-slim

      WORKDIR /app

      COPY requirements.txt .
      RUN pip install --no-cache-dir -r requirements.txt

      COPY . .

      ENV PYTHONUNBUFFERED=1
      EXPOSE #{port}

      CMD ["uvicorn", "#{app_module}:app", "--host", "0.0.0.0", "--port", "#{port}"]
    DOCKERFILE
  end

  def flask_template
    entry_point = @detection.metadata&.dig("entry_point") || "app.py"
    has_procfile = @detection.metadata&.dig("has_procfile")
    port        = @detection.port

    start_cmd = if has_procfile
      '["sh", "-c", "$(grep -m1 web Procfile | cut -d: -f2-)"]'
    else
      %(["gunicorn", "--bind", "0.0.0.0:#{port}", "--workers", "2", "#{File.basename(entry_point, '.py')}:app"])
    end

    <<~DOCKERFILE
      FROM python:3.11-slim

      WORKDIR /app

      COPY requirements.txt .
      RUN pip install --no-cache-dir -r requirements.txt gunicorn

      COPY . .

      ENV PYTHONUNBUFFERED=1
      EXPOSE #{port}

      CMD #{start_cmd}
    DOCKERFILE
  end

  def django_template
    wsgi   = @detection.metadata&.dig("wsgi_module") || "wsgi:application"
    port   = @detection.port

    <<~DOCKERFILE
      FROM python:3.11-slim

      WORKDIR /app

      COPY requirements.txt .
      RUN pip install --no-cache-dir -r requirements.txt gunicorn

      COPY . .

      ENV PYTHONUNBUFFERED=1
      ENV DJANGO_SETTINGS_MODULE=config.settings.production

      EXPOSE #{port}

      CMD ["gunicorn", "--bind", "0.0.0.0:#{port}", "--workers", "2", "#{wsgi}"]
    DOCKERFILE
  end

  def static_template
    <<~DOCKERFILE
      FROM nginx:alpine

      COPY . /usr/share/nginx/html

      # Remove server tokens from responses.
      RUN sed -i 's/^\\(\\s*server_tokens\\).*/\\1 off;/' /etc/nginx/nginx.conf || true

      EXPOSE 80

      CMD ["nginx", "-g", "daemon off;"]
    DOCKERFILE
  end

  def go_template
    go_version  = @detection.metadata&.dig("go_version") || "1.22"
    module_name = @detection.metadata&.dig("module_name") || "app"
    port        = @detection.port

    <<~DOCKERFILE
      # syntax=docker/dockerfile:1

      # ── Build stage ───────────────────────────────────────────────────────────
      FROM golang:#{go_version}-alpine AS build

      RUN apk add --no-cache git ca-certificates

      WORKDIR /src

      COPY go.mod go.sum ./
      RUN go mod download

      COPY . .

      RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /bin/app ./...

      # ── Final stage ───────────────────────────────────────────────────────────
      FROM gcr.io/distroless/static-debian12

      COPY --from=build /bin/app /app
      COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

      EXPOSE #{port}

      HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \\
        CMD ["/app", "-healthcheck"] || exit 1

      ENTRYPOINT ["/app"]
    DOCKERFILE
  end

  def bun_template
    port        = @detection.port
    start_cmd   = @detection.metadata&.dig("start_script") ? '["bun", "run", "start"]' : '["bun", "run", "index.ts"]'
    build_script = @detection.metadata&.dig("build_script")
    build_step   = build_script ? "RUN bun run build" : ""

    <<~DOCKERFILE
      FROM oven/bun:1-alpine AS build

      WORKDIR /app

      COPY package.json bun.lock* bun.lockb* ./
      RUN bun install --frozen-lockfile

      COPY . .
      #{build_step}

      FROM oven/bun:1-alpine

      WORKDIR /app
      COPY --from=build /app /app

      ENV NODE_ENV=production
      EXPOSE #{port}

      HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:#{port}/health || exit 1

      CMD #{start_cmd}
    DOCKERFILE
  end

  def elixir_template
    app_name   = @detection.metadata&.dig("mix_project") || "app"
    has_phoenix = @detection.metadata&.dig("has_phoenix")
    port        = @detection.port

    if has_phoenix
      <<~DOCKERFILE
        # syntax=docker/dockerfile:1

        # ── Build stage ───────────────────────────────────────────────────────────
        FROM hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.20.3 AS build

        RUN apk add --no-cache build-base git npm

        WORKDIR /app

        RUN mix local.hex --force && mix local.rebar --force

        ENV MIX_ENV=prod

        COPY mix.exs mix.lock ./
        RUN mix deps.get --only prod
        RUN mix deps.compile

        COPY assets assets
        RUN npm install --prefix assets && npm run deploy --prefix assets

        COPY . .
        RUN mix compile
        RUN mix assets.deploy
        RUN mix release

        # ── Final stage ───────────────────────────────────────────────────────────
        FROM alpine:3.20

        RUN apk add --no-cache libstdc++ openssl ncurses-libs

        WORKDIR /app

        RUN addgroup -g 1000 elixir && adduser -u 1000 -G elixir -s /bin/sh -D elixir
        USER elixir:elixir

        COPY --from=build --chown=elixir:elixir /app/_build/prod/rel/#{app_name} ./

        ENV PHX_SERVER=true
        EXPOSE #{port}

        HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:#{port}/health || exit 1

        CMD ["bin/#{app_name}", "start"]
      DOCKERFILE
    else
      <<~DOCKERFILE
        FROM hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.20.3

        RUN apk add --no-cache build-base git
        RUN mix local.hex --force && mix local.rebar --force

        WORKDIR /app

        ENV MIX_ENV=prod

        COPY mix.exs mix.lock ./
        RUN mix deps.get --only prod && mix deps.compile

        COPY . .
        RUN mix release

        EXPOSE #{port}

        CMD ["_build/prod/rel/#{app_name}/bin/#{app_name}", "start"]
      DOCKERFILE
    end
  end
end
