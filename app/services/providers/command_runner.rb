require "open3"

module Providers
  # The single place providers shell out. Commands are passed as argv arrays
  # (never through a shell), so values like image tags or env keys cannot
  # inject extra commands.
  #
  # Specs inject a fake runner that records argv and returns canned Results,
  # which is how we test providers without ever touching docker or gcloud.
  #
  #   runner = Providers::CommandRunner.new
  #   result = runner.call(%w[docker version], env: {}, log: ->(l) { puts l })
  #   result.success? # => true
  #   result.output   # => combined stdout+stderr
  class CommandRunner
    Result = Data.define(:output, :exit_status) do
      def success? = exit_status.zero?
    end

    # argv      — Array of command + arguments
    # env       — extra environment variables for the child process
    # log       — optional callable, receives each non-blank output line
    # on_spawn  — optional callable, receives the child PID (used for cancellation)
    # redact    — secret strings that must never reach `log`
    def call(argv, env: {}, log: nil, on_spawn: nil, redact: [])
      argv  = Array(argv).map(&:to_s)
      lines = []

      Open3.popen2e(env.transform_values(&:to_s), *argv) do |stdin, out, wait_thr|
        stdin.close
        on_spawn&.call(wait_thr.pid)
        out.each_line do |raw|
          line = scrub(raw.chomp, redact)
          lines << line
          log&.call(line) if line.present?
        end
        Result.new(output: lines.join("\n"), exit_status: wait_thr.value.exitstatus || 1)
      end
    rescue Errno::ENOENT => e
      Result.new(output: "#{argv.first}: command not found (#{e.message})", exit_status: 127)
    end

    private

    def scrub(line, secrets)
      Array(secrets).compact.reject(&:empty?).reduce(line) { |acc, s| acc.gsub(s, "[REDACTED]") }
    end
  end
end
