module Analysis
  # Knowledge about runtime versions: what we default to, which release
  # lines have official base images we're willing to pick, how to resolve a
  # version *range* (engines.node, requires-python) to one concrete line, and
  # which lines are end-of-life.
  #
  # Tables reflect upstream support status as of 2026-09. They are data, not
  # logic — update them when a runtime ships or goes EOL.
  module RuntimeVersions
    DEFAULTS = {
      "node"   => "22",
      "ruby"   => "3.4",
      "python" => "3.12",
      "go"     => "1.25",
      "bun"    => "1",
      "elixir" => "1.18"
    }.freeze

    # Elixir lines with a verified hexpm/elixir build image and the matching
    # Alpine runtime image (the release links against the builder's libs).
    ELIXIR_IMAGES = {
      "1.18" => [ "hexpm/elixir:1.18.4-erlang-27.3.4.16-alpine-3.22.5", "alpine:3.22.5" ],
      "1.17" => [ "hexpm/elixir:1.17.3-erlang-27.1.2-alpine-3.20.3", "alpine:3.20.3" ],
      "1.16" => [ "hexpm/elixir:1.16.3-erlang-26.2.5.21-alpine-3.22.6", "alpine:3.22.6" ]
    }.freeze

    # Release lines we resolve ranges against, newest first.
    NODE_LINES   = %w[24 22 20 18].freeze
    PYTHON_LINES = %w[3.13 3.12 3.11 3.10 3.9].freeze

    # Lines older than these are end-of-life upstream (warning).
    EOL_BELOW = {
      "node"   => "22",
      "ruby"   => "3.3",
      "python" => "3.10",
      "go"     => "1.25"
    }.freeze

    # Lines older than these can't produce a sane modern image (error).
    UNSUPPORTED_BELOW = {
      "node"   => "16",
      "ruby"   => "2.7",
      "python" => "3.8",
      "go"     => "1.18"
    }.freeze

    VERSION_RE = /\A\d+(\.\d+){0,2}\z/

    module_function

    # Normalises "v20.11.1\n" / "ruby-3.3.0" / "python-3.11.4" to "20.11.1" etc.
    # Returns nil for aliases such as "lts/*", "node", "system".
    def clean(value)
      v = value.to_s.strip.split(/\s+/).first.to_s
      v = v.sub(/\A(v|ruby-|python-|go)/, "")
      v.match?(VERSION_RE) ? v : nil
    end

    # Compares dotted versions numerically, missing components count as 0.
    def compare(a, b)
      pa = a.to_s.split(".").map(&:to_i)
      pb = b.to_s.split(".").map(&:to_i)
      len = [ pa.size, pb.size ].max
      pa.fill(0, pa.size...len) <=> pb.fill(0, pb.size...len)
    end

    def older_than?(version, floor)
      version && compare(version, floor).negative?
    end

    # Resolves a mix.exs requirement ("~> 1.15", "~> 1.16.2", ">= 1.14.0")
    # to an Elixir line we have images for.
    def elixir_line_for(requirement)
      req = requirement.to_s.strip
      floor = req[/\d+\.\d+/]
      return DEFAULTS["elixir"] unless floor

      lines = ELIXIR_IMAGES.keys
      pinned_minor = req.match?(/~>\s*\d+\.\d+\.\d+/) || req.match?(/\A=?=?\s*\d+\.\d+/)
      return floor if pinned_minor && lines.include?(floor)

      lines.select { |l| compare(l, floor) >= 0 }.max_by { |l| l.split(".").map(&:to_i) } || floor
    end

    # ── npm-style ranges (engines.node) ──────────────────────────────── #

    # Resolves an npm semver range to a Node major line. Prefers the default
    # line when it satisfies the range, otherwise the newest satisfying line,
    # otherwise the first major mentioned in the range.
    def node_line_for(range)
      range = range.to_s.strip
      return nil if range.empty?

      alternatives = range.split("||").map { |alt| npm_comparators(alt) }
      satisfies = ->(line) { alternatives.any? { |cmps| cmps.all? { |c| c.call(line) } } }

      return DEFAULTS["node"] if satisfies.call(DEFAULTS["node"])

      NODE_LINES.find { |l| satisfies.call(l) } || range[/\d+/]
    end

    def npm_comparators(alt)
      alt = alt.strip
      if (m = alt.match(/\A(\S+)\s+-\s+(\S+)\z/))
        return [ comparator(">=", m[1]), comparator("<=", m[2]) ]
      end

      alt.scan(/(\^|~>?|>=|<=|>|<|=)?\s*v?(\d+(?:\.(?:\d+|x|\*))*|\*|x)/i).map do |op, ver|
        next ->(_line) { true } if ver.match?(/\A[x*]\z/i)

        parts = ver.split(".").reject { |p| p.match?(/\A[x*]\z/i) }
        base  = parts.join(".")
        case op
        when "^"      then both(comparator(">=", base), comparator("<", (parts[0].to_i + 1).to_s))
        when "~", "~>" then both(comparator(">=", base), comparator("<=", parts.first(parts.size > 1 ? 2 : 1).join(".")))
        when nil, "=" then comparator("=", base)
        else comparator(op, base)
        end
      end
    end

    # ── PEP 440 / Poetry specifiers (requires-python) ───────────────── #

    def python_line_for(spec)
      spec = spec.to_s.strip
      return nil if spec.empty?

      if spec.match?(/\A\d+\.\d+(\.\d+)?\z/)
        return spec.split(".").first(2).join(".")
      end

      alternatives = spec.split("||").map { |alt| pep440_comparators(alt) }
      satisfies = ->(line) { alternatives.any? { |cmps| cmps.all? { |c| c.call(line) } } }

      return DEFAULTS["python"] if satisfies.call(DEFAULTS["python"])

      PYTHON_LINES.find { |l| satisfies.call(l) } || spec[/\d+\.\d+/]
    end

    def pep440_comparators(alt)
      alt.split(/[,\s]+(?=[<>=!~^*\d])/).map(&:strip).reject(&:empty?).map do |clause|
        m = clause.match(/\A(~=|===|==|!=|>=|<=|>|<|\^|~)?\s*(\d+(?:\.\d+)*)(\.\*)?\z/)
        next ->(_line) { true } unless m

        op, ver, wildcard = m[1], m[2], m[3]
        parts = ver.split(".")
        case op
        when "~=" then both(comparator(">=", ver), comparator("<=", parts.first([ parts.size - 1, 1 ].max).join(".")))
        when "^"  then both(comparator(">=", ver), comparator("<", (parts[0].to_i + 1).to_s))
        when "~"  then both(comparator(">=", ver), comparator("<=", parts.first(2).join(".")))
        when "==", "===", nil then comparator("=", ver)
        when "!="
          eq = comparator("=", ver)
          wildcard || parts.size <= 2 ? ->(line) { !eq.call(line) } : ->(_line) { true }
        else comparator(op, ver)
        end
      end
    end

    # A "line" such as "22" or "3.12" stands for its newest release, so we
    # compare it against a bound only at the bound's precision.
    def comparator(op, bound)
      bound_parts = bound.to_s.split(".").map(&:to_i)
      lambda do |line|
        cand = (line.to_s.split(".").map(&:to_i) + [ 999, 999, 999 ]).first(bound_parts.size)
        cmp  = cand <=> bound_parts
        case op
        when ">=" then cmp >= 0
        when ">"  then cmp.positive?
        when "<=" then cmp <= 0
        when "<"  then cmp.negative?
        else           line_matches_prefix?(line, bound_parts)
        end
      end
    end

    def line_matches_prefix?(line, bound_parts)
      lp = line.to_s.split(".").map(&:to_i)
      n  = [ lp.size, bound_parts.size ].min
      lp.first(n) == bound_parts.first(n)
    end

    def both(a, b)
      ->(line) { a.call(line) && b.call(line) }
    end
  end
end
