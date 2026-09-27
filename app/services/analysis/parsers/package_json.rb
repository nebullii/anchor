require "json"

module Analysis
  module Parsers
    # Parses package.json into a small, typed view.
    #
    #   pkg = Analysis::Parsers::PackageJson.parse(File.read("package.json"))
    #   pkg.dependency?("next")          # => true
    #   pkg.script("build")              # => "next build"
    #   pkg.line_for_dependency("next")  # => 7
    class PackageJson
      attr_reader :data, :content

      def self.parse(content)
        data = JSON.parse(content.to_s)
        raise ParseError, "package.json must contain a JSON object" unless data.is_a?(Hash)

        new(data, content.to_s)
      rescue JSON::ParserError => e
        raise ParseError, "package.json is not valid JSON: #{e.message.lines.first.to_s.strip[0, 120]}"
      end

      def initialize(data, content)
        @data    = data
        @content = content
      end

      def dependencies
        hash_at("dependencies")
      end

      def dev_dependencies
        hash_at("devDependencies")
      end

      def all_dependencies
        dev_dependencies.merge(dependencies)
      end

      def dependency?(name)
        all_dependencies.key?(name)
      end

      def dependency_matching?(prefix)
        all_dependencies.keys.any? { |k| k.start_with?(prefix) }
      end

      def scripts
        hash_at("scripts")
      end

      # The script body, or nil when absent/blank/non-string.
      def script(name)
        value = scripts[name]
        value.is_a?(String) && !value.strip.empty? ? value : nil
      end

      def main
        data["main"].is_a?(String) ? data["main"] : nil
      end

      def engines_node
        engines = data["engines"]
        engines.is_a?(Hash) && engines["node"].is_a?(String) ? engines["node"] : nil
      end

      # "pnpm@9.1.0+sha512.abc" -> ["pnpm", "9.1.0"]
      def package_manager
        value = data["packageManager"]
        return nil unless value.is_a?(String) && value.include?("@")

        name, version = value.split("@", 2)
        [ name, version.to_s.split("+").first ]
      end

      # Workspace globs from npm/yarn ("workspaces": [...] or {"packages": [...]}).
      def workspaces
        ws = data["workspaces"]
        ws = ws["packages"] if ws.is_a?(Hash)
        ws.is_a?(Array) ? ws.grep(String) : []
      end

      def line_for_dependency(name)
        line_for(%("#{name}"))
      end

      def line_for_script(name)
        line_for(%("#{name}"))
      end

      def line_for(needle)
        content.each_line.with_index(1) { |l, n| return n if l.include?(needle) }
        nil
      end

      private

      def hash_at(key)
        value = data[key]
        value.is_a?(Hash) ? value : {}
      end
    end
  end
end
