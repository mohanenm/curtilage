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
  # License to be chosen before publishing.

  spec.files = Dir["lib/**/*.rb", "sql/**/*.sql", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = []
  spec.require_paths = ["lib"]
end
