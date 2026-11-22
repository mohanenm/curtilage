# frozen_string_literal: true

require_relative "curtilage/version"

module Curtilage
  # Every error the gem raises on purpose is one of these (input mistakes
  # are ArgumentError).
  class Error < StandardError; end
end

require_relative "curtilage/config"
require_relative "curtilage/duckdb"
require_relative "curtilage/geometry"
require_relative "curtilage/validation"
require_relative "curtilage/features"
require_relative "curtilage/result"
require_relative "curtilage/generator"
require_relative "curtilage/generator_lot"
require_relative "curtilage/generator_store"
require_relative "curtilage/generator_details"
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
require_relative "curtilage/formats"
require_relative "curtilage/preview"

# Premises generation from OpenStreetMap data. Coordinates are [lng, lat]
# throughout, matching GeoJSON.
module Curtilage
  # Every review flag a result can carry, and what it asks a person to check.
  # The preview shows these on hover; README and the reference list them too.
  FLAGS = {
    near_houses: "The lot borders a home: check where the yard or property line is.",
    large_building: "Building over 5,000 m2: may be shared by several tenants.",
    small_building: "Building under 50 m2: may be a kiosk or canopy rather than the store.",
    building_not_under_pin: "No building under the pin; the nearest one within 30 m was used.",
    store_may_be_unit: "The store zone is a building over 1,500 m2: the store may be one unit of it.",
    shopping_centre: "The whole shopping centre was mapped (scope: :centre).",
    fallback: "The main method failed validation; the building rectangle was used.",
    ml_footprint: "Built on a machine-learned footprint, not an OSM building.",
    no_data: "No map data covers the pin.",
    partial_data: "Part of the area around the pin is in a region that isn't built.",
  }.freeze

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

  # The building at a pin (the one its premises would be made from), with
  # the same options as premises: { id:, name:, type:, area_m2:, footprint: }
  # (footprint: [[lng, lat], ...] closed), or nil if there is none.
  def self.building_at(pin, **)
    premises(pin, **, store_zone: false).details&.fetch(:building)
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

  SOURCES = %i[auto geofabrik overture].freeze
  # :auto builds a Geofabrik region once this many pins need it (or it's
  # already cached); fewer pins are cheaper to read from Overture. Measured:
  # Overture about 5.6 s a pin, a mid-size US state about 60-90 s to build.
  AUTO_BUILD_MIN_PINS = 10

  # Results for many pins, in pin order, looking features up once per group
  # of pins that share data.
  #
  # Where the data comes from (source:, default Curtilage.config.source):
  # - :auto (the default): regions with many pins (auto_build_min_pins:,
  #   default 10) or already in cache_dir are built from Geofabrik; scattered
  #   pins are read from Overture Maps, seconds each and nothing downloaded.
  # - :geofabrik: always build the pins' regions (private: the host only
  #   learns the region), in cache_dir if given (reused for a month), else in
  #   a temporary folder deleted afterwards.
  # - :overture: always read Overture Maps in place.
  # - catalogue: / parquet: regions built ahead of time (overrides source:).
  #
  # lookup: options for Lookup and the build (duckdb:, extension_directory:,
  # setup_sql:). data: max_age_days:, ml_footprints:, parallel_builds:,
  # auto_build_min_pins:, log: (where build progress goes, anything with
  # puts; default $stderr), release: (Overture). keep_features: true keeps each
  # result's map data (Result#features, which Preview draws); by default it's
  # dropped to save memory. Other options go to generate.
  def self.generate_many(pins, keep_features: false, **)
    results = fetch_and_generate(pins, **)
    results.each { |r| r.features = nil } unless keep_features
    results
  end

  def self.fetch_and_generate(pins, source: nil, catalogue: nil, parquet: nil, cache_dir: nil, lookup: {}, data: {},
                              **options)
    lookup = duckdb_options(lookup)
    return run_many(pins, catalogue, parquet, lookup, options) if catalogue || parquet

    source = (source || config.source).to_sym
    unless SOURCES.include?(source)
      raise ArgumentError,
            "unknown source #{source.inspect} (have: #{SOURCES.join(", ")})"
    end
    return from_overture(pins, lookup, data, options) if source == :overture

    auto = AutoData.new(cache_dir: cache_dir || config.cache_dir, **lookup.slice(:duckdb, :extension_directory),
                        **data.slice(:max_age_days, :ml_footprints, :parallel_builds, :log))
    built, read = if source == :auto
                    auto_plan(pins, auto, data.fetch(:auto_build_min_pins, AUTO_BUILD_MIN_PINS))
                  else
                    [pins.each_index.to_a, []]
                  end
    build_and_read(pins, built, read, auto, lookup: lookup, data: data, options: options)
  ensure
    auto&.cleanup
  end

  # [indexes to build from Geofabrik, indexes to read from Overture]. A pin
  # is built only if every region around it is worth building or cached;
  # pins in no Geofabrik region (anywhere without shapefiles) go to Overture.
  def self.auto_plan(pins, auto, min_pins)
    around = pins.map { |pin| auto.regions.around(pin, Lookup::DEFAULT_RADIUS_DEG) }
    counts = around.flatten.map(&:path).tally
    build = counts.keys.select { |path| counts[path] >= min_pins || auto.fresh_region?(path) }
    pins.each_index.partition { |i| around[i].any? && around[i].all? { |r| build.include?(r.path) } }
  end

  # Builds and Overture reads wait on different hosts: run them side by side.
  # If the reads fail, the builds are allowed to finish before the error is
  # raised: the caller then deletes their temporary folder, which must not
  # happen under a running build.
  def self.build_and_read(pins, built, read, auto, lookup:, data:, options:)
    builds = Thread.new { from_builds(pins.values_at(*built), auto, lookup, options) }
    builds.report_on_exception = false # value re-raises it
    begin
      reads = read.empty? ? [] : from_overture(pins.values_at(*read), lookup, data, options)
    rescue StandardError
      wait_quietly(builds)
      raise
    end
    merge(pins.size, [built, builds.value], [read, reads])
  end

  # The read error is the one to report, not a build error behind it.
  def self.wait_quietly(thread)
    thread.join
  rescue StandardError
    nil
  end

  def self.from_builds(pins, auto, lookup, options)
    return [] if pins.empty?

    run_many(pins, auto.catalogue_for(pins), nil, lookup, options).each do |r|
      r.explanation.unshift("map data: OpenStreetMap, built from Geofabrik")
    end
  end

  def self.merge(size, *parts)
    results = Array.new(size)
    parts.each { |indexes, list| indexes.zip(list).each { |i, r| results[i] = r } }
    results
  end

  def self.from_overture(pins, lookup, data, options)
    lists = Overture.features_many(pins, **lookup.slice(:duckdb, :extension_directory, :radius_deg),
                                   **data.slice(:release))
    pins.zip(lists).map do |pin, features|
      generate(pin, features, **options).tap do |r|
        r.attribution = Overture::ATTRIBUTION
        r.explanation.unshift("map data: OpenStreetMap, read from Overture Maps")
      end
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

  private_class_method :fetch_and_generate, :auto_plan, :build_and_read, :wait_quietly, :from_builds, :merge,
                       :from_overture, :run_many, :preset_options, :generate_one, :partial_data, :no_data
end
