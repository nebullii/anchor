module Analysis
  module Parsers
    # Static reader for a Gemfile. The Gemfile is Ruby code, so we never eval
    # it; we recognise the declarative subset every real Gemfile uses:
    #   gem "name", "~> 1.0", group: :test
    #   ruby "3.3.0"  /  ruby file: ".ruby-version"
    #   group :development, :test do ... end
    class Gemfile
      GemEntry = Struct.new(:name, :requirement, :line, :groups, keyword_init: true)

      GEM_RE       = /\A\s*gem\s*\(?\s*["']([^"']+)["']\s*(?:,\s*["']([^"']+)["'])?/
      RUBY_RE      = /\A\s*ruby\s*\(?\s*["']([^"']+)["']/
      RUBY_FILE_RE = /\A\s*ruby\s*\(?\s*file:\s*["']([^"']+)["']/
      GROUP_RE     = /\A\s*group\s+(.+?)\s+do\b/
      BLOCK_OPEN_RE = /\bdo\s*(\|[^|]*\|)?\s*\z/

      attr_reader :gems, :ruby_requirement, :ruby_file, :ruby_line

      def self.parse(content)
        new(content.to_s)
      end

      def initialize(content)
        @gems = []
        @ruby_requirement = nil
        @ruby_file = nil
        @ruby_line = nil
        parse(content)
      end

      def gem?(name)
        gems.any? { |g| g.name == name }
      end

      def find(name)
        gems.find { |g| g.name == name }
      end

      private

      def parse(content)
        # Stack of group lists; non-group blocks (platforms, source ... do)
        # push an empty list so `end` pops the right thing.
        stack = []
        content.each_line.with_index(1) do |raw, number|
          line = raw.sub(/#.*$/, "").rstrip

          if (m = line.match(GROUP_RE))
            stack.push(m[1].scan(/:(\w+)|["'](\w+)["']/).flatten.compact)
          elsif line.match?(BLOCK_OPEN_RE)
            stack.push([])
          elsif line.match?(/\A\s*end\b/)
            stack.pop
          elsif (m = line.match(GEM_RE))
            inline = line.scan(/groups?:\s*(\[[^\]]*\]|:\w+)/).flatten
                         .flat_map { |g| g.scan(/:(\w+)/).flatten }
            @gems << GemEntry.new(name: m[1], requirement: m[2], line: number,
                                  groups: (stack.flatten + inline).uniq)
          elsif (m = line.match(RUBY_FILE_RE))
            @ruby_file = m[1]
            @ruby_line = number
          elsif (m = line.match(RUBY_RE))
            @ruby_requirement = m[1]
            @ruby_line = number
          end
        end
      end
    end
  end
end
