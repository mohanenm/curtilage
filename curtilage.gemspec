# frozen_string_literal: true

require_relative "lib/curtilage/version"

Gem::Specification.new do |spec|
  spec.name = "curtilage"
  spec.version = Curtilage::VERSION
  spec.authors = ["mohanenm"]
  spec.summary = "Generate a site's premises polygon (building + lot) from OpenStreetMap data."
  spec.description = <<~TEXT
    Builds compact per-region Parquet files of OpenStreetMap buildings, parking and roads,
    looks up the features around a point, and proposes a premises polygon with validation
    and an explanation of how it was made. No outside services are called at runtime.
  TEXT
  spec.required_ruby_version = ">= 3.2"
  spec.license = "MIT"
  # To do before publishing: spec.homepage (the GitHub repo) and the
  # homepage_uri, source_code_uri, changelog_uri and bug_tracker_uri metadata.
  # spec.email is optional; it is shown publicly on rubygems.org.

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "sql/**/*.sql", "exe/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
