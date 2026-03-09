module Analysis
  # Detects database adapter by reading dependency manifests.
  # Returns a hash like { "adapter" => "postgresql", "var" => "DATABASE_URL" }
  # or nil if no database dependency is found.
  class DatabaseDetector
    RUBY_ADAPTERS = {
      "pg"     => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "mysql2" => { "adapter" => "mysql",      "var" => "DATABASE_URL" },
      "sqlite3"=> { "adapter" => "sqlite",     "var" => nil            },
    }.freeze

    PYTHON_ADAPTERS = {
      "psycopg2"              => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "psycopg2-binary"       => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "asyncpg"               => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "sqlalchemy"            => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "databases"             => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "tortoise-orm"          => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "mysql-connector-python"=> { "adapter" => "mysql",      "var" => "DATABASE_URL" },
      "pymysql"               => { "adapter" => "mysql",      "var" => "DATABASE_URL" },
      "django"                => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
    }.freeze

    NODE_ADAPTERS = {
      "pg"        => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "postgres"  => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "mysql"     => { "adapter" => "mysql",      "var" => "DATABASE_URL" },
      "mysql2"    => { "adapter" => "mysql",      "var" => "DATABASE_URL" },
      "mongoose"  => { "adapter" => "mongodb",    "var" => "MONGODB_URI"  },
      "sequelize" => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "prisma"    => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "@prisma/client" => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "knex"      => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
      "typeorm"   => { "adapter" => "postgresql", "var" => "DATABASE_URL" },
    }.freeze

    def initialize(repo_path, framework)
      @repo_path = repo_path
      @framework = framework
    end

    def call
      case @framework
      when "rails"                           then check_gemfile
      when "python", "fastapi", "flask", "django" then check_requirements
      when "node", "nextjs"                  then check_package_json
      end
    end

    private

    def check_gemfile
      path = File.join(@repo_path, "Gemfile")
      return nil unless File.exist?(path)
      content = File.read(path)
      RUBY_ADAPTERS.each { |gem, info| return info if content.match?(/gem ['"]#{Regexp.escape(gem)}['"]/) }
      nil
    end

    def check_requirements
      path = File.join(@repo_path, "requirements.txt")
      unless File.exist?(path)
        # Fall back to pyproject.toml
        pyproj = File.join(@repo_path, "pyproject.toml")
        return check_pyproject if File.exist?(pyproj)
        return nil
      end

      deps = File.readlines(path).map { |l| l.split(/[>=<!~\[;\s]/)[0].strip.downcase }
      PYTHON_ADAPTERS.each { |pkg, info| return info if deps.include?(pkg.downcase) }
      nil
    end

    def check_pyproject
      content = File.read(File.join(@repo_path, "pyproject.toml")).downcase
      PYTHON_ADAPTERS.each { |pkg, info| return info if content.include?(pkg.downcase) }
      nil
    end

    def check_package_json
      path = File.join(@repo_path, "package.json")
      return nil unless File.exist?(path)

      pkg      = JSON.parse(File.read(path))
      all_deps = (pkg["dependencies"] || {}).merge(pkg["devDependencies"] || {})
      NODE_ADAPTERS.each { |dep, info| return info if all_deps.key?(dep) }
      nil
    end
  end
end
