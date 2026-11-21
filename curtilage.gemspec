# frozen_string_literal: true

require_relative "lib/curtilage/version"

Gem::Specification.new do |spec|
  spec.name = "curtilage"
  spec.version = Curtilage::VERSION
  spec.authors = ["Emil M"]
  spec.email = ["curtilage.cohesive702@8shield.net"]
  spec.summary = "Generate a site's premises polygon (building + lot) from OpenStreetMap data."
  spec.description = <<~TEXT
    Proposes a premises polygon for a location (the building and its customer-facing lot,
    bounded by roads, railways and neighbours) plus the building's own outline, with review
    flags, validation and an explanation of each step. Map data is free and needs no hosting:
    OpenStreetMap regions are built on demand from Geofabrik, or read in place from Overture
    Maps. Rule-based; machine-learned footprints are opt-in.
  TEXT
  spec.required_ruby_version = ">= 3.2"
  spec.license = "MIT"
  # To do before publishing: spec.homepage (the GitHub repo) and the
  # homepage_uri, source_code_uri, changelog_uri and bug_tracker_uri metadata.

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "sql/**/*.sql", "exe/*", "docs/**/*.md", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
