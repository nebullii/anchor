# Fails when a migration added on this branch would break the app revision
# that is still serving while the deploy runs.
#
# Deploys migrate first and shift traffic second (.github/workflows/_deploy.yml),
# so for a few minutes the OLD code runs against the NEW schema. Dropping or
# renaming a column/table the old code still reads breaks production during
# that window. Do it in two deploys instead ("expand/contract"):
#
#   1. expand   — add the new column, write to both, stop reading the old one
#   2. contract — in a later deploy, remove the old column
#
# A contract migration must say so explicitly with a comment:
#
#   # anchor:contract — old column unused since <commit/PR>
#
# Usage: ruby script/check_migrations.rb [base-ref]      (default: origin/main)
#        ruby script/check_migrations.rb --files a.rb b.rb (check given files)

UNSAFE = {
  /\bremove_column\b/    => "removes a column",
  /\bremove_columns\b/   => "removes columns",
  /\brename_column\b/    => "renames a column",
  /\brename_table\b/     => "renames a table",
  /\bdrop_table\b/       => "drops a table",
  /\bremove_reference\b/ => "removes a reference",
  /\bchange_column\b/    => "changes a column's type"
}.freeze

if ARGV.first == "--files"
  added = ARGV.drop(1)
else
  base  = ARGV[0] || "origin/main"
  added = `git diff --name-only --diff-filter=A #{base}...HEAD -- db/migrate 2>/dev/null`.split("\n")
  unless $?.success?
    warn "Could not diff against #{base}; checking no migrations."
    exit 0
  end
end

# Lines outside `def down ... end` — the rollback path never runs during a deploy.
def forward_lines(source)
  down_indent = nil
  source.each_line.with_index(1).reject do |line, _|
    if down_indent
      down_indent = nil if line =~ /\A#{down_indent}end\b/
      true
    elsif (m = line.match(/\A(\s*)def down\b/))
      down_indent = m[1]
      true
    end
  end
end

problems = added.flat_map do |path|
  source = File.read(path)
  next [] if source.include?("anchor:contract")

  forward_lines(source).flat_map do |line, number|
    next [] if line.strip.start_with?("#")

    UNSAFE.filter_map { |pattern, what| [ path, number, what ] if line.match?(pattern) }
  end
end

if problems.empty?
  puts "Migration safety: #{added.size} new migration(s), all backward compatible."
  exit 0
end

problems.each do |path, number, what|
  puts "::error file=#{path},line=#{number}::Migration #{what}. The revision still serving " \
       "during the deploy may break. Split into expand/contract deploys, or add an " \
       "'# anchor:contract' comment once no running code uses it."
end
exit 1
