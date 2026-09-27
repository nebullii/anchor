module Ai
  module Eval
    # Offline evaluation harness for Ai::ErrorExplainer.
    #
    # Loads YAML fixtures (spec/fixtures/ai_evals/*.yml), runs each through
    # the explainer with the given client, and grades the result with
    # Ai::Eval::Grader. The same pipeline runs:
    #   * in CI against a WebMock-stubbed client (tests parsing + grading)
    #   * manually via `bin/rails anchor:ai_eval` against a real provider
    #     (tests prompt quality; costs money, never run automatically)
    #
    #   report = Ai::Eval::Runner.new(client: Ai::Client.new(tier: :fast)).run
    #   report.pass_rate  # => 0.92
    class Runner
      DEFAULT_DIR = Rails.root.join("spec/fixtures/ai_evals")

      Report = Struct.new(:cases, keyword_init: true) do
        def passed
          cases.count(&:passed?)
        end

        def pass_rate
          cases.empty? ? 0.0 : passed.to_f / cases.size
        end

        # Fraction of cases passing each individual check.
        def check_rates
          names = cases.flat_map { |c| c.checks.keys }.uniq
          names.to_h do |name|
            applicable = cases.select { |c| c.checks.key?(name) }
            [ name, applicable.count { |c| c.checks[name] }.to_f / applicable.size ]
          end
        end

        def to_h
          {
            "pass_rate"   => pass_rate.round(3),
            "passed"      => passed,
            "total"       => cases.size,
            "check_rates" => check_rates.transform_values { |v| v.round(3) },
            "cases"       => cases.map(&:to_h)
          }
        end
      end

      def self.load_fixtures(dir = DEFAULT_DIR)
        Dir.glob(File.join(dir.to_s, "*.yml")).sort.map do |path|
          YAML.safe_load_file(path).merge("file" => File.basename(path))
        end
      end

      def initialize(client:, fixtures: nil, dir: DEFAULT_DIR)
        @client   = client
        @fixtures = fixtures || self.class.load_fixtures(dir)
      end

      def run
        Report.new(cases: @fixtures.map { |fixture| run_case(fixture) })
      end

      private

      def run_case(fixture)
        context = ErrorExplainer::Context.new(
          framework:      fixture["framework"],
          branch:         fixture["branch"] || "main",
          error_message:  fixture["error_message"].to_s,
          logs:           fixture["logs"].to_s,
          error_category: Deployments::ErrorCategorizer.categorize(fixture["error_message"].to_s),
          secrets:        Array(fixture["secrets"])
        )

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result  = ErrorExplainer.new(context: context, client: @client).call
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        request_body = @client.respond_to?(:last_request_body) ? @client.last_request_body : nil
        Grader.new(fixture).grade(result, request_body: request_body, elapsed: elapsed)
      end
    end
  end
end
