module Analysis
  # Finds the deployable app(s) in a repository and picks one.
  #
  # Single-app repos resolve to the root. Monorepos (JS workspaces, turbo/nx,
  # or simply several app folders) are scanned one or two levels deep; every
  # app found is reported as a candidate and the most likely one is chosen:
  #
  #   1. an explicit root_dir (project setting) always wins;
  #   2. otherwise the repo root, unless it is only a workspace manifest;
  #   3. otherwise the highest-confidence sub-app (ties: framework preference,
  #      then shallowest, then alphabetical — deterministic).
  class AppLocator
    Result = Struct.new(:chosen, :candidates, :workspace, :reason, :ambiguous, keyword_init: true)

    WORKSPACE_MARKERS = %w[pnpm-workspace.yaml turbo.json nx.json lerna.json rush.json go.work].freeze
    CONTAINER_DIRS    = %w[apps packages services projects sites web frontend backend].freeze
    SKIP_DIRS = (FileSet::IGNORED_DIRS + %w[
      test tests spec specs fixtures __tests__ e2e examples example docs doc scripts
      app src lib config bin db public static assets templates migrations internal pkg cmd
    ]).freeze
    MAX_DIRS = 60

    def initialize(repo_path, root_dir: nil)
      @repo_path = repo_path
      @root_dir  = root_dir
    end

    def call
      return explicit_root if @root_dir.present?

      root_detector = DirectoryDetector.new(@repo_path, ".")
      root          = root_detector.call
      workspace     = workspace_root?(root)
      subs          = sub_candidates(workspace, include_static: root.nil?)

      chosen, reason =
        if root && !(workspace && subs.any?)
          [ root, "application found at repository root" ]
        elsif subs.any?
          [ pick(subs), "repository root is not an app; picked the most likely of #{subs.size} app(s)" ]
        else
          [ root || fallback("."), root ? "workspace root" : "no recognizable application found" ]
        end

      # A bare workspace manifest is not an app anyone wants deployed.
      candidates = ((workspace && subs.any? ? [] : [ root ]) + subs).compact
      ambiguous  = chosen && candidates.count { |c| c.confidence >= chosen.confidence - 0.05 } > 1 && chosen.root_dir != "." || false

      if ambiguous
        chosen.evidence += [ { "file" => nil, "line" => nil,
                              "reason" => "#{candidates.size} candidate apps found; picked #{chosen.root_dir} — set the project's root directory to override" } ]
        chosen.confidence = (chosen.confidence * 0.85).round(2)
      end

      Result.new(chosen: chosen, candidates: candidates, workspace: workspace, reason: reason, ambiguous: ambiguous)
    end

    private

    def explicit_root
      rel = normalize_root(@root_dir)
      unless rel
        chosen = fallback(".")
        chosen.evidence += [ { "file" => nil, "line" => nil, "reason" => "configured root directory #{@root_dir.inspect} does not exist in the repository" } ]
        return Result.new(chosen: chosen, candidates: [], workspace: false, reason: "invalid root_dir", ambiguous: false)
      end

      workspace = workspace_root?(nil) ? "." : nil
      chosen = DirectoryDetector.new(@repo_path, rel, workspace_root: workspace).call || fallback(rel)
      chosen.evidence = [ { "file" => nil, "line" => nil, "reason" => "project root directory set to #{rel}" } ] + chosen.evidence
      Result.new(chosen: chosen, candidates: [ chosen ], workspace: !workspace.nil?, reason: "project root_dir", ambiguous: false)
    end

    # Rejects absolute paths and anything that escapes the checkout.
    def normalize_root(value)
      rel = value.to_s.strip.delete_prefix("./").delete_suffix("/")
      return "." if rel.empty? || rel == "."
      return nil if rel.start_with?("/") || rel.split("/").include?("..")

      full = File.expand_path(rel, @repo_path)
      return nil unless full.start_with?(File.expand_path(@repo_path) + "/") && File.directory?(full)

      rel
    end

    def workspace_root?(root)
      files = FileSet.new(@repo_path)
      marker = WORKSPACE_MARKERS.any? { |m| files.exist?(m) }
      pkg = (Parsers::PackageJson.parse(files.read("package.json").to_s) rescue nil)
      has_ws = marker || (pkg && pkg.workspaces.any?)
      return false unless has_ws
      return true if root.nil?

      # A root that is itself a real app (Next.js, Rails, a Dockerfile...) is
      # still deployed from the root; a bare workspace package.json is not.
      root.framework == "node" && root.confidence < 0.85
    end

    def sub_candidates(workspace, include_static:)
      candidate_dirs(workspace).filter_map do |dir|
        c = DirectoryDetector.new(@repo_path, dir, workspace_root: workspace ? "." : nil).call
        next nil unless c
        next nil if c.framework == "static" && !include_static

        c
      end
    end

    def candidate_dirs(workspace)
      dirs = children(".").reject { |d| SKIP_DIRS.include?(d) }
      nested = dirs.select { |d| CONTAINER_DIRS.include?(d) }
      nested |= workspace_globs.map { |g| g.split("/").first }.select { |d| File.directory?(File.join(@repo_path, d)) } if workspace

      nested.each do |parent|
        children(parent).each do |child|
          next if SKIP_DIRS.include?(child)

          dirs << File.join(parent, child)
        end
      end
      dirs.uniq.sort.first(MAX_DIRS)
    end

    def children(rel)
      base = rel == "." ? @repo_path : File.join(@repo_path, rel)
      Dir.children(base).sort.select do |name|
        !name.start_with?(".") && File.directory?(File.join(base, name)) && !File.symlink?(File.join(base, name))
      end
    rescue SystemCallError
      []
    end

    def workspace_globs
      files = FileSet.new(@repo_path)
      globs = (Parsers::PackageJson.parse(files.read("package.json").to_s).workspaces rescue [])
      pnpm = files.read("pnpm-workspace.yaml").to_s
      globs + pnpm.scan(/^\s*-\s*["']?([^"'\s]+)["']?/).flatten
    end

    def pick(subs)
      subs.min_by do |c|
        [ -c.confidence, DirectoryDetector::PREFERENCE.index(c.framework).to_i, c.root_dir.count("/"), c.root_dir ]
      end
    end

    def fallback(root_dir)
      DirectoryDetector::Candidate.new(
        framework: "static", runtime: "nginx", port: DirectoryDetector::DEFAULT_PORTS["static"],
        confidence: 0.1, root_dir: root_dir, errors: [],
        evidence: [ { "file" => nil, "line" => nil, "reason" => "no recognizable application found; falling back to a static site" } ],
        metadata: { "undetected" => true }
      )
    end
  end
end
