namespace :anchor do
  desc "Run the AI error-explainer eval set against the configured provider (costs money; never run in CI)"
  task ai_eval: :environment do
    client = Ai::Client.new(tier: :fast)
    abort "anchor:ai_eval — no AI provider configured (set ANTHROPIC_API_KEY or OPENAI_API_KEY)." unless client.enabled?

    dir      = ENV.fetch("EVAL_DIR", Ai::Eval::Runner::DEFAULT_DIR.to_s)
    min_rate = ENV.fetch("MIN_PASS_RATE", "0.8").to_f
    fixtures = Ai::Eval::Runner.load_fixtures(dir)
    abort "anchor:ai_eval — no fixtures in #{dir}" if fixtures.empty?

    puts "Running #{fixtures.size} eval cases on #{client.provider} / #{client.model} ..."
    report = Ai::Eval::Runner.new(client: client, fixtures: fixtures).run

    report.cases.each do |c|
      status = c.passed? ? "PASS" : "FAIL"
      detail = c.passed? ? "" : "  failed: #{c.failed_checks.join(', ')}"
      puts format("  %-4s %-36s %-22s %5.1fs%s", status, c.id, c.result&.category.to_s, c.elapsed.to_f, detail)
    end

    puts
    report.check_rates.each { |name, rate| puts format("  %-22s %5.1f%%", name, rate * 100) }
    puts format("\nPass rate: %d/%d (%.1f%%), threshold %.0f%%",
                report.passed, report.cases.size, report.pass_rate * 100, min_rate * 100)

    if (out = ENV["EVAL_OUT"]).present?
      File.write(out, JSON.pretty_generate(report.to_h))
      puts "Report written to #{out}"
    end

    abort "anchor:ai_eval — pass rate below threshold" if report.pass_rate < min_rate
  end
end
