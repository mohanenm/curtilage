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
    OpenStreetMap data is read in place from Overture Maps for scattered locations, or built
    from Geofabrik regions where many locations share one. Rule-based; machine-learned
    footprints are opt-in.
  TEXT
  spec.required_ruby_version = ">= 3.2"
  spec.license = "MIT"
  spec.homepage = "https://github.com/mohanenm/curtilage"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/docs/reference.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  # Docs are listed by name: design notes, recipes and drafts under docs/
  # stay out of the gem unless added here.
  spec.files = Dir["lib/**/*.rb", "sql/**/*.sql", "exe/*"] +
               %w[docs/reference.md docs/security.md README.md CHANGELOG.md LICENSE.txt SECURITY.md]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
