module Analysis
  module Parsers
    # Raised by every manifest parser when a file cannot be understood.
    # Callers catch it, record a "malformed manifest" finding and carry on —
    # a broken file must never crash analysis.
    class ParseError < StandardError
      attr_reader :line

      def initialize(message, line: nil)
        @line = line
        super(line ? "#{message} (line #{line})" : message)
      end
    end
  end
end
