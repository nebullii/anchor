module Analysis
  # Reads top-level dependency names from the project's manifest file.
  # Returns a plain array of strings — used for warnings and analysis display.
  class DependencyReader
    def initialize(repo_path, framework)
      @repo_path = repo_path
      @framework = framework
    end

    def call
      case @framework
      when "rails"                                then read_gemfile
      when "python", "fastapi", "flask", "django" then read_requirements
      when "node", "nextjs"                       then read_package_json
      else []
      end
    rescue => e
      Rails.logger.warn("DependencyReader failed for #{@framework}: #{e.message}")
      []
    end

    private

    def read_gemfile
      path = File.join(@repo_path, "Gemfile")
      return [] unless File.exist?(path)

      File.readlines(path)
          .grep(/^\s*gem ['"]/)
          .filter_map { |l| l.match(/gem ['"]([^'"]+)['"]/)[1] rescue nil }
    end

    def read_requirements
      path = File.join(@repo_path, "requirements.txt")
      return [] unless File.exist?(path)

      File.readlines(path)
          .map    { |l| l.split(/[>=<!~\[;\s]/)[0].to_s.strip }
          .reject { |l| l.empty? || l.start_with?("#") }
    end

    def read_package_json
      path = File.join(@repo_path, "package.json")
      return [] unless File.exist?(path)

      pkg = JSON.parse(File.read(path))
      (pkg["dependencies"] || {}).keys
    end
  end
end
