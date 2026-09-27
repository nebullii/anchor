module Analysis
  module Parsers
    # Parser for go.mod: module path, `go` directive, `toolchain` directive
    # and requirements (single-line and block form). Comments are stripped.
    class GoMod
      Require = Struct.new(:path, :version, :line, keyword_init: true)

      attr_reader :module_path, :go_version, :go_line, :toolchain, :requires

      def self.parse(content)
        new(content.to_s)
      end

      def initialize(content)
        @module_path = nil
        @go_version  = nil
        @go_line     = nil
        @toolchain   = nil
        @requires    = []
        parse(content)
      end

      # "1.22.3" -> "1.22"
      def go_minor
        go_version && go_version[/\A\d+\.\d+/]
      end

      private

      def parse(content)
        block = nil
        content.each_line.with_index(1) do |raw, number|
          line = raw.sub(%r{//.*$}, "").strip
          next if line.empty?

          if block
            if line == ")"
              block = nil
            elsif block == "require"
              add_require(line, number)
            end
            next
          end

          directive, rest = line.split(/\s+/, 2)
          rest = rest.to_s.strip
          case directive
          when "module"
            @module_path = rest.delete('"')
          when "go"
            raise ParseError.new("invalid go directive #{rest.inspect}", line: number) unless rest.match?(/\A\d+\.\d+(\.\d+)?(rc\d+|beta\d+)?\z/)

            @go_version = rest
            @go_line = number
          when "toolchain"
            @toolchain = rest.delete_prefix("go")
          when "require", "replace", "exclude", "retract", "tool", "godebug", "ignore"
            if rest == "("
              block = directive
            elsif directive == "require"
              add_require(rest, number)
            end
          else
            raise ParseError.new("unknown go.mod directive #{directive.inspect}", line: number)
          end
        end

        raise ParseError, "go.mod has no module directive" if @module_path.nil? && !content.strip.empty?
      end

      def add_require(text, number)
        path, version = text.split(/\s+/)
        @requires << Require.new(path: path, version: version, line: number) if path
      end
    end
  end
end
