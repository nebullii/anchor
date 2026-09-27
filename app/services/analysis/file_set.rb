module Analysis
  # Read-only, crash-proof view over a checked-out directory.
  #
  # Every analysis component reads files through this class so that:
  #   * missing / unreadable / binary / huge files never raise,
  #   * content is always valid UTF-8 (invalid bytes are scrubbed),
  #   * directory walks skip vendored and generated trees and are sorted,
  #     which keeps detection (and therefore generated Dockerfiles) deterministic.
  class FileSet
    IGNORED_DIRS = %w[
      .git node_modules vendor .bundle __pycache__ .venv venv env .tox .mypy_cache
      .pytest_cache .next .nuxt .output .svelte-kit dist build tmp log coverage
      _build deps target .turbo .cache .yarn .pnpm-store
    ].freeze

    MAX_READ_BYTES = 2_000_000

    attr_reader :root

    def initialize(root)
      @root = root.to_s
    end

    def path(rel)
      rel.to_s.empty? || rel == "." ? @root : File.join(@root, rel)
    end

    def exist?(rel)
      File.file?(path(rel))
    end

    def dir?(rel)
      File.directory?(path(rel))
    end

    # Returns the file's content as scrubbed UTF-8, or nil when the file is
    # missing, a directory, unreadable, or larger than MAX_READ_BYTES.
    def read(rel)
      full = path(rel)
      return nil unless File.file?(full)
      return nil if File.size(full) > MAX_READ_BYTES

      File.binread(full).force_encoding(Encoding::UTF_8).scrub("")
    rescue SystemCallError, IOError
      nil
    end

    # Lists files (relative paths, sorted) under the root whose basename
    # matches one of `extensions` (e.g. %w[.js .ts]) or, when `names` is given,
    # whose basename equals one of `names`. Skips IGNORED_DIRS.
    def files(extensions: nil, names: nil, limit: 2_000, max_depth: 8)
      results = []
      walk(@root, "", 0, max_depth) do |rel|
        base = File.basename(rel)
        ext_ok  = extensions && extensions.include?(File.extname(base))
        name_ok = names && names.include?(base)
        results << rel if ext_ok || name_ok || (extensions.nil? && names.nil?)
        break if results.size >= limit
      end
      results.sort
    end

    # Returns [[rel_path, line_number, line_text], ...] for every line in the
    # selected files matching `regex`. Line numbers are 1-based.
    def grep(regex, extensions:, limit: 200, file_limit: 1_500)
      hits = []
      files(extensions: extensions, limit: file_limit).each do |rel|
        content = read(rel)
        next unless content

        content.each_line.with_index(1) do |line, number|
          next unless line.match?(regex)

          hits << [ rel, number, line.chomp ]
          return hits if hits.size >= limit
        end
      end
      hits
    end

    # 1-based line number of the first line matching `pattern` (String or
    # Regexp) in `rel`, or nil.
    def line_of(rel, pattern)
      content = read(rel)
      return nil unless content

      content.each_line.with_index(1) do |line, number|
        matched = pattern.is_a?(Regexp) ? line.match?(pattern) : line.include?(pattern)
        return number if matched
      end
      nil
    end

    private

    def walk(abs_dir, rel_dir, depth, max_depth, &block)
      return if depth > max_depth

      entries = Dir.children(abs_dir).sort
      entries.each do |name|
        abs = File.join(abs_dir, name)
        rel = rel_dir.empty? ? name : File.join(rel_dir, name)
        next if File.symlink?(abs)

        if File.directory?(abs)
          next if IGNORED_DIRS.include?(name)

          walk(abs, rel, depth + 1, max_depth, &block)
        else
          yield rel
        end
      end
    rescue SystemCallError
      nil
    end
  end
end
