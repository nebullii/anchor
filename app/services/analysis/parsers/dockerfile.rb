module Analysis
  module Parsers
    # Minimal Dockerfile reader: joins continuation lines and yields
    # instructions with the line number they start on.
    class Dockerfile
      Instruction = Struct.new(:keyword, :args, :line, keyword_init: true)

      attr_reader :instructions

      def self.parse(content)
        new(content.to_s)
      end

      def initialize(content)
        @instructions = []
        parse(content)
      end

      def all(keyword)
        instructions.select { |i| i.keyword == keyword }
      end

      # [[port(Integer), line], ...] from EXPOSE instructions of the final stage.
      def exposed_ports
        final_stage.select { |i| i.keyword == "EXPOSE" }.flat_map do |i|
          i.args.split(/\s+/).filter_map do |token|
            port = token.split("/").first
            [ port.to_i, i.line ] if port.match?(/\A\d+\z/)
          end
        end
      end

      # The USER of the final stage, or nil (image default, usually root).
      def final_user
        final_stage.select { |i| i.keyword == "USER" }.last&.args
      end

      def final_stage
        start = instructions.rindex { |i| i.keyword == "FROM" }
        start ? instructions[start..] : instructions
      end

      private

      def parse(content)
        buffer = +""
        start  = nil
        content.each_line.with_index(1) do |raw, number|
          line = raw.chomp
          next if buffer.empty? && (line.strip.empty? || line.lstrip.start_with?("#"))
          next if !buffer.empty? && line.lstrip.start_with?("#") # comments inside continuations

          start ||= number
          if line.end_with?("\\")
            buffer << line.chomp("\\") << " "
            next
          end
          buffer << line
          add(buffer, start)
          buffer = +""
          start = nil
        end
        add(buffer, start) unless buffer.strip.empty?
      end

      def add(text, line)
        keyword, args = text.strip.split(/\s+/, 2)
        @instructions << Instruction.new(keyword: keyword.upcase, args: args.to_s.strip, line: line)
      end
    end
  end
end
