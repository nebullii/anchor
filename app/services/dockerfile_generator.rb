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
    when "rails"  then rails_template
    when "node"   then node_template
    when "python" then python_template
    when "static" then static_template
    else               nil   # "docker" framework already has a Dockerfile
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
      FROM ruby:#{ruby_version}-slim

      RUN apt-get update -qq && \\
          apt-get install -y --no-install-recommends \\
            build-essential \\
            libpq-dev \\
            nodejs \\
            curl && \\
          rm -rf /var/lib/apt/lists/*

      WORKDIR /app

      #{copy_lock}
      RUN bundle install --without development test --jobs 4 --retry 3

      COPY . .

      # Precompile assets — ignore errors for API-only apps.
      RUN SECRET_KEY_BASE=placeholder bundle exec rails assets:precompile 2>/dev/null || true

      ENV RAILS_ENV=production
      ENV RAILS_LOG_TO_STDOUT=true
      ENV RAILS_SERVE_STATIC_FILES=true

      EXPOSE #{port}

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
end
