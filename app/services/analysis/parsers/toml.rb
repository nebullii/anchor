module Analysis
  module Parsers
    # A small, dependency-free TOML reader covering what pyproject.toml,
    # Pipfile, uv.lock and poetry.lock actually use:
    #
    #   * [table], [a.b], [[array.of.tables]], quoted keys, dotted keys
    #   * basic / literal / multi-line strings, integers, floats, booleans,
    #     dates (returned as strings), arrays (multi-line, nested, trailing
    #     commas, comments) and inline tables
    #
    # Raises ParseError (with a line number) on anything it can't read, so a
    # malformed file becomes a preflight finding rather than a crash.
    class Toml
      def self.parse(content)
        new(content.to_s).parse
      end

      def initialize(content)
        @s    = content.delete_prefix("﻿")
        @pos  = 0
        @root = {}
      end

      def parse
        current = @root
        loop do
          skip_ws_comments_newlines
          break if eof?

          if peek == "["
            current = parse_table_header
          else
            parse_key_value(current)
          end
          expect_line_end
        end
        @root
      end

      private

      # ── Structure ────────────────────────────────────────────────────── #

      def parse_table_header
        array = @s[@pos, 2] == "[["
        @pos += array ? 2 : 1
        skip_inline_ws
        keys = parse_key
        skip_inline_ws
        closing = array ? "]]" : "]"
        error("expected #{closing}") unless @s[@pos, closing.length] == closing
        @pos += closing.length

        parent = dig_create(@root, keys[0..-2])
        last   = keys.last
        if array
          parent[last] ||= []
          error("#{keys.join('.')} is not an array of tables") unless parent[last].is_a?(Array)
          table = {}
          parent[last] << table
          table
        else
          parent[last] ||= {}
          error("#{keys.join('.')} is not a table") unless parent[last].is_a?(Hash)
          parent[last]
        end
      end

      def parse_key_value(table)
        keys = parse_key
        skip_inline_ws
        error("expected '=' after key") unless peek == "="
        @pos += 1
        skip_inline_ws
        value  = parse_value
        target = dig_create(table, keys[0..-2])
        target[keys.last] = value
      end

      def parse_key
        keys = []
        loop do
          skip_inline_ws
          keys << case peek
          when '"' then parse_basic_string
          when "'" then parse_literal_string
          else
                    m = @s[@pos, 256].match(/\A[A-Za-z0-9_-]+/)
                    error("invalid key") unless m
                    @pos += m[0].length
                    m[0]
          end
          skip_inline_ws
          break unless peek == "."

          @pos += 1
        end
        keys
      end

      def dig_create(table, keys)
        keys.reduce(table) do |t, k|
          node = t[k]
          node = node.last if node.is_a?(Array) && node.last.is_a?(Hash)
          unless node.is_a?(Hash)
            error("key #{k} already has a non-table value") unless node.nil?
            node = t[k] = {}
          end
          node
        end
      end

      # ── Values ───────────────────────────────────────────────────────── #

      def parse_value
        case peek
        when '"'
          @s[@pos, 3] == '"""' ? parse_multiline_basic : parse_basic_string
        when "'"
          @s[@pos, 3] == "'''" ? parse_multiline_literal : parse_literal_string
        when "[" then parse_array
        when "{" then parse_inline_table
        else parse_scalar
        end
      end

      def parse_scalar
        m = @s[@pos, 64].match(/\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}[^\s,\]\}#]*|\A[^\s,\]\}#]+/)
        error("expected a value") unless m
        token = m[0]
        @pos += token.length
        case token
        when "true"  then true
        when "false" then false
        when /\A[+-]?\d[\d_]*\z/ then token.delete("_").to_i
        when /\A0x[0-9a-fA-F_]+\z/ then token.delete("_").to_i(16)
        when /\A[+-]?(\d[\d_]*)?(\.\d[\d_]*)?([eE][+-]?\d+)?\z/ then token.delete("_").to_f
        when /\A[+-]?(inf|nan)\z/ then token.include?("inf") ? Float::INFINITY : Float::NAN
        when /\A\d{4}-\d{2}-\d{2}/, /\A\d{2}:\d{2}/ then token # dates/times kept as strings
        else error("invalid value #{token[0, 30].inspect}")
        end
      end

      def parse_basic_string
        @pos += 1
        out = +""
        loop do
          error("unterminated string") if eof? || peek == "\n"
          c = @s[@pos]
          if c == '"'
            @pos += 1
            return out
          elsif c == "\\"
            out << parse_escape
          else
            out << c
            @pos += 1
          end
        end
      end

      def parse_literal_string
        @pos += 1
        close = @s.index("'", @pos)
        error("unterminated string") if close.nil? || @s[@pos...close].include?("\n")
        value = @s[@pos...close]
        @pos = close + 1
        value
      end

      def parse_multiline_basic
        @pos += 3
        @pos += 1 if peek == "\n"
        out = +""
        loop do
          error("unterminated multi-line string") if eof?
          if @s[@pos, 3] == '"""'
            @pos += 3
            # Up to two extra quotes may belong to the content.
            while peek == '"'
              out << '"'
              @pos += 1
            end
            return out
          elsif peek == "\\"
            if @s[@pos + 1..].to_s.match?(/\A[ \t]*\n/)
              @pos += 1
              @pos += 1 while [ " ", "\t", "\n", "\r" ].include?(peek)
            else
              out << parse_escape
            end
          else
            out << peek
            @pos += 1
          end
        end
      end

      def parse_multiline_literal
        @pos += 3
        @pos += 1 if peek == "\n"
        close = @s.index("'''", @pos)
        error("unterminated multi-line string") unless close
        value = @s[@pos...close]
        @pos = close + 3
        value
      end

      def parse_escape
        @pos += 1
        c = @s[@pos]
        @pos += 1
        case c
        when "n" then "\n"
        when "t" then "\t"
        when "r" then "\r"
        when "b" then "\b"
        when "f" then "\f"
        when '"' then '"'
        when "\\" then "\\"
        when "u", "U"
          len = c == "u" ? 4 : 8
          hex = @s[@pos, len]
          error("invalid unicode escape") unless hex&.match?(/\A\h{#{len}}\z/)
          @pos += len
          [ hex.to_i(16) ].pack("U")
        else error("invalid escape \\#{c}")
        end
      end

      def parse_array
        @pos += 1
        items = []
        loop do
          skip_ws_comments_newlines
          if peek == "]"
            @pos += 1
            return items
          end
          items << parse_value
          skip_ws_comments_newlines
          if peek == ","
            @pos += 1
          elsif peek != "]"
            error("expected ',' or ']' in array")
          end
        end
      end

      def parse_inline_table
        @pos += 1
        table = {}
        skip_inline_ws
        if peek == "}"
          @pos += 1
          return table
        end
        loop do
          skip_inline_ws
          parse_key_value(table)
          skip_inline_ws
          case peek
          when "," then @pos += 1
          when "}"
            @pos += 1
            return table
          else error("expected ',' or '}' in inline table")
          end
        end
      end

      # ── Lexing helpers ───────────────────────────────────────────────── #

      def peek
        @s[@pos]
      end

      def eof?
        @pos >= @s.length
      end

      def skip_inline_ws
        @pos += 1 while peek == " " || peek == "\t"
      end

      def skip_comment
        @pos += 1 until eof? || peek == "\n" if peek == "#"
      end

      def skip_ws_comments_newlines
        loop do
          start = @pos
          @pos += 1 while [ " ", "\t", "\n", "\r" ].include?(peek)
          skip_comment
          break if @pos == start
        end
      end

      def expect_line_end
        skip_inline_ws
        skip_comment
        @pos += 1 if peek == "\r"
        return if eof?
        error("expected end of line") unless peek == "\n"
      end

      def error(message)
        line = @s[0...@pos].count("\n") + 1
        raise ParseError.new("invalid TOML: #{message}", line: line)
      end
    end
  end
end
