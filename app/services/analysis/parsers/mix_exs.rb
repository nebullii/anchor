module Analysis
  module Parsers
    # Static reader for an Elixir mix.exs. Like the Gemfile it is code, so we
    # extract the declarative pieces: the OTP app name, the Elixir requirement
    # and the dependency tuples ({:phoenix, "~> 1.7"}).
    class MixExs
      Dep = Struct.new(:name, :requirement, :line, keyword_init: true)

      attr_reader :app_name, :elixir_requirement, :deps

      def self.parse(content)
        new(content.to_s)
      end

      def initialize(content)
        @app_name = nil
        @elixir_requirement = nil
        @deps = []
        parse(content)
      end

      def dep?(name)
        deps.any? { |d| d.name == name }
      end

      def line_of(name)
        deps.find { |d| d.name == name }&.line
      end

      private

      def parse(content)
        raise ParseError, "mix.exs does not define a module" unless content.strip.empty? || content.include?("defmodule")

        content.each_line.with_index(1) do |raw, number|
          line = raw.sub(/#.*$/, "")
          @app_name ||= line[/\bapp:\s*:([a-z_][a-zA-Z0-9_]*)/, 1]
          @elixir_requirement ||= line[/\belixir:\s*"([^"]+)"/, 1]
          line.scan(/\{\s*:([a-z_][a-zA-Z0-9_]*)\s*,\s*(?:"([^"]*)")?/) do |name, req|
            @deps << Dep.new(name: name, requirement: req, line: number)
          end
        end
      end
    end
  end
end
