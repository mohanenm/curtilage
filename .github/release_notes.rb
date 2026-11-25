# frozen_string_literal: true

# Prints the CHANGELOG section for a version (without its heading), for the
# GitHub release; fails when there's none. Used by .github/workflows/release.yml.
version = ARGV.fetch(0)
section = File.read(File.expand_path("../CHANGELOG.md", __dir__), encoding: "utf-8")[
  /^## \[#{Regexp.escape(version)}\].*?(?=^## \[|\z)/m
]
abort "no CHANGELOG section for #{version}" unless section
puts section.lines.drop(1).join.strip
