# frozen_string_literal: true

require_relative "curtilage/version"
require_relative "curtilage/config"
require_relative "curtilage/geometry"
require_relative "curtilage/validation"
require_relative "curtilage/features"
require_relative "curtilage/generator"
require_relative "curtilage/generator_lot"
require_relative "curtilage/generator_store"
require_relative "curtilage/lookup"
require_relative "curtilage/download"
require_relative "curtilage/zip_range"
require_relative "curtilage/footprints"
require_relative "curtilage/build"
require_relative "curtilage/catalogue"
require_relative "curtilage/regions"
require_relative "curtilage/auto_data"
require_relative "curtilage/overture"
require_relative "curtilage/audit"

# Premises generation from OpenStreetMap data. Coordinates are [lng, lat]
# throughout, matching GeoJSON.
module Curtilage
  # Named styles; any option passed alongside a preset overrides it.
  PRESETS = {
    # The building and its whole lot: parking up to the kerb, railways and a
    # strip short of neighbours. The default.
    whole_lot: {},
    # The building plus a small margin, still trimmed at roads.
    tight: { method: :building, building_margin_m: 8 },
    # Like whole_lot, but a store in a shopping centre gets the whole centre.
    centre: { scope: :centre },
  }.freeze

  # Premises for one pin, fetching its map data as configured (see
  # generate_many for the options). The simplest way in:
  #
  #   result = Curtilage.premises([-80.0, 35.0])
  #   result.ok? && result.ring
  def self.premises(pin, **)
    generate_many([pin], **).first
  end

  # Premises for one pin from features you already have (Lookup.features).
  # With no method or preset, the recommended method with its fallback
  # (Generator.propose).
  def self.generate(pin, features, method: nil, preset: nil, **options)
    opts = preset_options(preset).merge(options)
    method ||= opts.delete(:method)
    opts.delete(:method)
    method ? Generator.generate(method, pin, features, **opts) : Generator.propose(pin, features, **opts)
  end

  # Results for many pins, in pin order, looking features up once per group
  # of pins that share data files.
  #
  # Where the data comes from:
  # - source: :geofabrik (the default, or Curtilage.config.source): built on demand from Geofabrik for
  #   just the regions the pins are in (AutoData), in cache_dir if given
  #   (reused for a month), else in a temporary folder deleted afterwards.
  #   Minutes per region the first time; nothing to host.
  # - source: :overture: read in place from Overture Maps' public release,
  #   seconds per batch, nothing downloaded or hosted (Overture).
  # - catalogue: a Catalogue of regions built ahead of time.
  # - parquet: a path or URL, or a list of them.
  #
  # lookup: options for Lookup and the build (duckdb:, extension_directory:,
  # setup_sql:). data: options for AutoData (max_age_days:, ml_footprints:).
  # Other options go to generate.
  def self.generate_many(pins, source: nil, catalogue: nil, parquet: nil, cache_dir: nil, lookup: {}, data: {},
                         **options)
    source = (source || config.source).to_sym
    cache_dir ||= config.cache_dir
    lookup = duckdb_options(lookup)
    return from_overture(pins, lookup, data, options) if source == :overture && !(catalogue || parquet)
    raise ArgumentError, "unknown source #{source.inspect} (have: geofabrik, overture)" unless source == :geofabrik

    auto = nil
    unless catalogue || parquet
      auto = AutoData.new(cache_dir: cache_dir, **lookup.slice(:duckdb, :extension_directory), **data)
      catalogue = auto.catalogue_for(pins)
    end
    run_many(pins, catalogue, parquet, lookup, options)
  ensure
    auto&.cleanup
  end

  def self.from_overture(pins, lookup, data, options)
    lists = Overture.features_many(pins, **lookup.slice(:duckdb, :extension_directory, :radius_deg),
                                   **data.slice(:release))
    pins.zip(lists).map do |pin, features|
      generate(pin, features, **options).tap { |r| r.attribution = Overture::ATTRIBUTION }
    end
  end

  def self.run_many(pins, catalogue, parquet, lookup, options)
    results = Array.new(pins.size)
    groups = pins.each_index.group_by { |i| catalogue ? catalogue.files_for(pins[i]) : Array(parquet) }
    groups.each do |files, indexes|
      lists = if files.empty?
                indexes.map { [] }
              else
                Lookup.features_many(parquet: files, pins: pins.values_at(*indexes), **lookup)
              end
      indexes.zip(lists).each { |i, features| results[i] = generate_one(pins[i], features, files, catalogue, options) }
    end
    results
  end

  def self.preset_options(preset)
    return {} if preset.nil?

    PRESETS.fetch(preset) do
      raise ArgumentError, "unknown preset #{preset.inspect} (have: #{PRESETS.keys.join(", ")})"
    end.dup
  end

  def self.generate_one(pin, features, files, catalogue, options)
    result = generate(pin, features, **options)
    if files.empty?
      no_data(result)
    elsif catalogue && catalogue.coverage(pin) == :partial
      partial_data(result)
    end
    result
  end

  def self.partial_data(result)
    result.flags << :partial_data
    result.explanation.unshift("part of the area around the pin is in a region that isn't built: " \
                               "buildings or roads there are missing")
  end

  def self.no_data(result)
    result.flags << :no_data
    result.explanation.unshift("no map data covers this pin")
  end
end
