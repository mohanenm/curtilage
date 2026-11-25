# frozen_string_literal: true

require_relative "lib/curtilage/version"

Gem::Specification.new do |spec|
  spec.name = "curtilage"
  spec.version = Curtilage::VERSION
  spec.authors = ["Emil M"]
  spec.email = ["curtilage.cohesive702@8shield.net"]
  spec.summary = "Free lot outlines (building + parking, up to the kerb) for any business, from open map data."
  spec.description = <<~TEXT
    Generates a site's premises polygon (the building and its customer-facing parking lot,
    stopping at public roads, railways and neighbours) and the building's outline from a
    single point, for site selection, research, location analytics, geofencing and delivery zones.
    Each polygon comes with review flags, a confidence score, validation and an explanation
    of every step. Free map data, no hosting: OpenStreetMap read in place from Overture Maps,
    or built from Geofabrik extracts. Rule-based (no machine learning); outputs GeoJSON,
    NDJSON, CSV, KML, GeoParquet, GeoPackage and FlatGeobuf, with a CLI and an HTTP API.
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
  spec.files = Dir["lib/**/*.rb", "sql/**/*.sql", "exe/*", "docs/schema/*.json"] +
               %w[docs/reference.md docs/security.md docs/openapi.yaml README.md CHANGELOG.md LICENSE.txt SECURITY.md]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
