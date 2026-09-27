# Test double for Providers::CommandRunner. Records every command a provider
# would run and returns canned results — so provider specs assert on exact
# gcloud/docker argv without ever executing them.
#
#   runner = FakeCommandRunner.new
#   runner.stub(/builds submit/, output: "build-123")
#   runner.stub(/run deploy/, output: "boom 503", exit_status: 1)
#   provider = Providers::GcpCloudRun.new(project, runner: runner)
#   runner.commands # => [["gcloud", "builds", "submit", ...], ...]
class FakeCommandRunner
  Call = Struct.new(:argv, :env, :redact, keyword_init: true) do
    def line = argv.join(" ")
  end

  attr_reader :calls

  def initialize
    @calls = []
    @rules = []
  end

  # matcher: Regexp against the joined command line, or a String prefix.
  # Later stubs win over earlier ones. `output` may be a callable(argv).
  def stub(matcher, output: "", exit_status: 0)
    @rules.unshift([ matcher, output, exit_status ])
    self
  end

  def call(argv, env: {}, log: nil, on_spawn: nil, redact: [])
    argv = Array(argv).map(&:to_s)
    @calls << Call.new(argv: argv, env: env, redact: redact)
    on_spawn&.call(424242)

    _, output, status = @rules.find { |m, *| matches?(m, argv.join(" ")) } || [ nil, "", 0 ]
    output = output.call(argv) if output.respond_to?(:call)
    output.to_s.each_line { |l| log&.call(l.chomp) if l.strip.present? }
    Providers::CommandRunner::Result.new(output: output.to_s, exit_status: status)
  end

  def commands
    calls.map(&:argv)
  end

  def lines
    calls.map(&:line)
  end

  def find(pattern)
    calls.find { |c| c.line.match?(pattern) }
  end

  private

  def matches?(matcher, line)
    matcher.is_a?(Regexp) ? line.match?(matcher) : line.start_with?(matcher)
  end
end
