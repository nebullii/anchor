module Analysis
  module Parsers
    # Parser for pip requirements files (requirements.txt and friends).
    #
    # Handles comments, blank lines, line continuations ("\"), pip options
    # (-r, -c, --index-url ...), editable installs, extras ("uvicorn[standard]"),
    # environment markers ("; python_version < '3.11'") and PEP 508 direct
    # references ("pkg @ https://..."). Names are normalised per PEP 503.
    class Requirements
      Requirement = Struct.new(:name, :specifier, :line, keyword_init: true)

      NAME_RE = /\A([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*(.*)\z/

      def self.parse(content)
        new(content.to_s).requirements
      end

      # PEP 503 normalisation: "Flask_SQLAlchemy" -> "flask-sqlalchemy".
      def self.normalize(name)
        name.to_s.downcase.gsub(/[-_.]+/, "-")
      end

      # Parses one PEP 508 dependency string ("fastapi[all]>=0.110; python_version>'3.8'").
      # Returns [normalized_name, specifier] or nil.
      def self.parse_pep508(str)
        m = str.to_s.strip.match(NAME_RE)
        return nil unless m

        spec = m[3].split(";").first.to_s.strip
        [ normalize(m[1]), spec.start_with?("@") ? "" : spec ]
      end

      attr_reader :requirements

      def initialize(content)
        @requirements = []
        parse(content)
      end

      private

      def parse(content)
        pending = +""
        start_line = nil

        content.each_line.with_index(1) do |raw, number|
          line = raw.chomp
          start_line ||= number
          if line.end_with?("\\")
            pending << line.chomp("\\") << " "
            next
          end

          pending << line
          handle(pending, start_line)
          pending = +""
          start_line = nil
        end
        handle(pending, start_line) unless pending.empty?
      end

      def handle(line, number)
        text = line.sub(/(\A|\s)#.*\z/, "").strip
        return if text.empty?
        return if text.start_with?("-") # -r, -c, -e, --index-url and other pip options
        return if text.match?(%r{\A(\.|/|git\+|https?://|file:)}) # local paths / bare URLs

        parsed = self.class.parse_pep508(text)
        @requirements << Requirement.new(name: parsed[0], specifier: parsed[1], line: number) if parsed
      end
    end
  end
end
