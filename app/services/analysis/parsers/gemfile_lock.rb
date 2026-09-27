module Analysis
  module Parsers
    # Parser for Bundler's Gemfile.lock format.
    #
    # The lockfile is line-oriented: unindented section headers (GEM, GIT,
    # PATH, PLATFORMS, DEPENDENCIES, RUBY VERSION, BUNDLED WITH, CHECKSUMS),
    # with resolved specs at 4 spaces ("    rails (7.1.3)") and their own
    # dependencies at 6 spaces. We deliberately don't use
    # Bundler::LockfileParser: it depends on global Bundler state and warns or
    # raises on lockfiles produced by other Bundler versions.
    class GemfileLock
      Spec = Struct.new(:name, :version, :platform, :line, keyword_init: true)

      SECTIONS = [ "GEM", "GIT", "PATH", "PLATFORMS", "DEPENDENCIES", "RUBY VERSION",
                  "BUNDLED WITH", "CHECKSUMS", "PLUGIN SOURCE" ].freeze
      SPEC_RE  = /\A {4}([^\s(]+) \(([^)]+)\)\s*\z/
      CONFLICT_RE = /\A(<{7}|={7}|>{7})(\s|\z)/

      attr_reader :specs, :dependencies, :platforms, :ruby_version, :bundler_version

      def self.parse(content)
        new(content.to_s)
      end

      def initialize(content)
        @specs        = {}
        @dependencies = []
        @platforms    = []
        @ruby_version = nil
        @bundler_version = nil
        parse(content)
      end

      def gem?(name)
        specs.key?(name)
      end

      def version_of(name)
        specs[name]&.version
      end

      def line_of(name)
        specs[name]&.line
      end

      private

      def parse(content)
        section = nil
        seen_section = false

        content.each_line.with_index(1) do |raw, number|
          line = raw.chomp
          raise ParseError.new("Gemfile.lock contains unresolved merge conflict markers", line: number) if line.match?(CONFLICT_RE)
          next if line.strip.empty?

          unless line.start_with?(" ")
            header = line.strip
            raise ParseError.new("unknown Gemfile.lock section #{header[0, 40].inspect}", line: number) unless SECTIONS.include?(header)

            section = header
            seen_section = true
            next
          end

          case section
          when "GEM", "GIT", "PATH"
            if (m = line.match(SPEC_RE))
              version, platform = split_platform(m[2])
              @specs[m[1]] ||= Spec.new(name: m[1], version: version, platform: platform, line: number)
            end
          when "PLATFORMS"
            @platforms << line.strip
          when "DEPENDENCIES"
            @dependencies << line.strip.split(/[\s(!]/).first
          when "RUBY VERSION"
            # "   ruby 3.3.0p0" -> "3.3.0"
            m = line.match(/ruby (\d+\.\d+(?:\.\d+)?)/)
            @ruby_version = m[1] if m
          when "BUNDLED WITH"
            @bundler_version = line.strip
          when nil
            raise ParseError.new("Gemfile.lock content before any section header", line: number)
          end
        end

        raise ParseError, "Gemfile.lock has no recognizable sections" if !seen_section && !content.strip.empty?
      end

      # "1.16.4-x86_64-linux" -> ["1.16.4", "x86_64-linux"]
      def split_platform(value)
        m = value.match(/\A(\d[\w.]*?)(?:-([a-z].*))?\z/)
        m ? [ m[1], m[2] ] : [ value, nil ]
      end
    end
  end
end
