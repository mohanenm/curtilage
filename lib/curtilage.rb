# frozen_string_literal: true

require_relative "curtilage/version"
require_relative "curtilage/error"
require_relative "curtilage/config"
require_relative "curtilage/duckdb"
require_relative "curtilage/geometry"
require_relative "curtilage/geometry_rings"
require_relative "curtilage/grid"
require_relative "curtilage/validation"
require_relative "curtilage/features"
require_relative "curtilage/result"
require_relative "curtilage/confidence"
require_relative "curtilage/generator"
require_relative "curtilage/generator_lot"
require_relative "curtilage/generator_partition"
require_relative "curtilage/generator_centre"
require_relative "curtilage/generator_roads"
require_relative "curtilage/generator_store"
require_relative "curtilage/generator_details"
require_relative "curtilage/generator_steps"
require_relative "curtilage/generator_zones"
require_relative "curtilage/generator_pin"
require_relative "curtilage/generator_entrances"
require_relative "curtilage/generator_parcels"
require_relative "curtilage/generator_shared"
require_relative "curtilage/candidates"
require_relative "curtilage/profiles"
require_relative "curtilage/corrections"
require_relative "curtilage/diff"
require_relative "curtilage/missing_buildings"
require_relative "curtilage/h3"
require_relative "curtilage/gis_formats"
require_relative "curtilage/batch"
require_relative "curtilage/lookup"
require_relative "curtilage/parcels"
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
require_relative "curtilage/doctor"
require_relative "curtilage/server"
require_relative "curtilage/server_request"

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
    large_centre: "The centre is over centre_max_m2 (scope: :centre): the premises are the site's own share, " \
                  "not the whole centre.",
    shared_lot: "The lot is shared with other buildings and was split by nearest building: where it really " \
                "divides isn't in the map, so check the line.",
    takes_in_building: "shared_checks: the premises take in another building (not a canopy or car park): if it's " \
                       "another business's, trim the premises off it.",
    crosses_road: "The premises hold part of a public road: they should stop at it. Usually the pin is on or " \
                  "across the road from the building; check it.",
    pin_moved: "The pin wasn't on a building and was moved onto the nearest one (snap_m:): check it's the right one.",
    fallback: "The main method failed validation; the building rectangle was used.",
    ml_footprint: "Built on a machine-learned footprint, not an OSM building.",
    unit_estimated: "The store zone is an estimated unit of a large building (unit_m:): check it.",
    beyond_parcel: "The site's parking runs past the building's parcel (parcels supplied): check the property line.",
    shared_parcel: "parcel_mode :grow: the building's parcel also holds other businesses' buildings, " \
                   "so it was used only as a limit.",
    no_data: "No map data covers the pin.",
    partial_data: "Part of the area around the pin is in a region that isn't built.",
    error: "Generating this site raised an error (see its explanation); the rest of the batch went on.",
  }.freeze

  # Named styles; any option passed alongside a preset overrides it.
  # Options whose values are names, for callers that read them as text
  # (profiles, the HTTP API, the benchmark's JSON).
  NAMED_OPTIONS = (Generator.choices.select { |_, allowed| allowed.all?(Symbol) }.keys + %i[method preset]).freeze

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

  # Whether point ([lng, lat]) is inside ring (premises as stored:
  # [[lng, lat], ...], closed or not), on its edge counting as inside: the
  # check a geofence makes for a device's location. In plain Ruby, flat
  # around the ring (accurate to well under a metre at premises scale).
  def self.point_in_premises?(ring, point)
    lng, lat = Validation.pin(point)
    raise ArgumentError, "ring must be a list of [lng, lat] corners" unless ring.is_a?(Array) && ring.size >= 3 &&
                                                                            Geometry.valid_coordinates?(ring)

    xy = Geometry.open_ring(Geometry.project(ring, [lng, lat]))
    Geometry.contains?(xy, [0.0, 0.0]) || Geometry.distance_to_edges(xy, [0.0, 0.0]) < 0.01
  end

  # The building at a pin (the one its premises would be made from), with
  # the same options as premises: { id:, name:, type:, area_m2:, footprint: }
  # (footprint: [[lng, lat], ...] closed), or nil if there is none.
  def self.building_at(pin, **)
    premises(pin, **, store_zone: false).details&.fetch(:building)
  end

  # Places from Overture Maps to generate premises for, when you have no
  # pins: one filter (category:, brand: or ids:, see Overture.places) inside
  # a region (a US state such as "virginia", or a Geofabrik path, looked up
  # in Geofabrik's region index and matched to its outline) or a bbox:
  # [west, south, east, north]. Each place's pin feeds generate_many:
  #
  #   places = Curtilage.places(region: "delaware", category: "pharmacy")
  #   results = Curtilage.generate_many(places.map { |p| p[:pin] })
  def self.places(region: nil, bbox: nil, **)
    raise ArgumentError, "give region: or bbox:, not both" unless region.nil? ^ bbox.nil?
    return Overture.places(bbox: bbox, **) if bbox

    path = Build.region_path(region)
    area = Regions.download.regions.find { |r| r.path == path } or
      raise ArgumentError, "no Geofabrik region #{path} (see https://download.geofabrik.de)"
    Overture.places(bbox: area.bbox, **).select { |place| area.covers?(place[:pin]) }
  end

  # Premises for one pin from features you already have (Lookup.features).
  # With no method or preset, the recommended method with its fallback
  # (Generator.propose).
  #
  # candidates: N (1 to 5) also returns up to N other premises the site
  # could have, in Result#candidates (see Candidates).
  def self.generate(pin, features, method: nil, preset: nil, candidates: nil, **options)
    opts = preset_options(preset).merge(options)
    method ||= opts.delete(:method)
    opts.delete(:method)
    result = method ? Generator.generate(method, pin, features, **opts) : Generator.propose(pin, features, **opts)
    return result unless candidates

    result.tap do |r|
      r.candidates = Candidates.for(r, pin, features, { method: method, preset: preset, **options }.compact, candidates)
    end
  end

  SOURCES = %i[auto geofabrik overture].freeze
  # :auto builds a Geofabrik region once this many pins need it (or it's
  # already cached); fewer pins are cheaper to read from Overture. Measured:
  # Overture about 5.6 s a pin, a mid-size US state about 60-90 s to build.
  AUTO_BUILD_MIN_PINS = 10
  # One call's worth: more is likely a mistake, and a bigger batch should be
  # split so a failure costs less (max_pins: raises it).
  MAX_PINS_PER_CALL = 100_000
  DATA_OPTIONS = %i[max_age_days ml_footprints parallel_builds log auto_build_min_pins release].freeze

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
  #
  # corrections: { pin index => ring (or { ring:, store_ring: }) } uses
  # those polygons instead of generating (see Corrections); their pins
  # fetch no data.
  #
  # parcels: property lines you supply (a GeoJSON file, or GeoParquet local
  # or at a URL): the premises are clipped to the building's parcel (see
  # Parcels). Nothing is fetched unless you point it at a URL.
  def self.generate_many(pins, keep_features: false, max_pins: MAX_PINS_PER_CALL, corrections: {}, parcels: nil,
                         **options)
    pins = checked_pins(pins, max_pins)
    fixed = Corrections.checked(corrections, pins.size)
    rest = pins.each_index.reject { |i| fixed.key?(i) }
    todo = pins.values_at(*rest)
    generated = rest.empty? ? [] : fetch_and_generate(todo, **with_parcels(todo, parcels, options))
    manual = fixed.map do |i, c|
      Corrections.result(pins[i], c[:ring], store_ring: c[:store_ring], validation: options.fetch(:validation, {}))
    end
    results = merge(pins.size, [rest, generated], [fixed.keys, manual])
    results.each { |r| [r, *r.candidates].each { |c| c.features = nil } } unless keep_features
    results
  end

  # The options, with the parcels near the pins if given.
  def self.with_parcels(pins, parcels, options)
    return options unless parcels

    options.merge(parcel_index: Parcels.near(parcels, pins, options.fetch(:lookup, {})))
  end

  # Every pin checked before any data is fetched, so a bad one fails the
  # call at once (naming it) rather than after builds have run.
  def self.checked_pins(pins, max)
    raise ArgumentError, "pins must be a list of [lng, lat] pins" unless pins.is_a?(Array)
    raise ArgumentError, "#{pins.size} pins is more than max_pins (#{max}): split the batch" if pins.size > max

    pins.each_with_index.map do |pin, i|
      Validation.pin(pin)
    rescue ArgumentError => e
      raise ArgumentError, "pin #{i + 1}: #{e.message}"
    end
  end

  # Options are checked once, before any work, so a mistake in them fails
  # the call instead of turning every site into an error result.
  def self.check_generation_options(options)
    count = options[:candidates]
    unless count.nil? || (count.is_a?(Integer) && count.between?(1, Candidates::MAX))
      raise ArgumentError, "candidates must be a whole number from 1 to #{Candidates::MAX}: #{count.inspect}"
    end

    opts = preset_options(options[:preset]).merge(options.except(:preset, :candidates, :parcel_index))
    method = opts.delete(:method)
    raise ArgumentError, "unknown method #{method.inspect}" if method && !Generator::METHODS.include?(method)

    Generator.checked_options(opts)
  end

  # One site's result, never an exception: a site whose generation raises
  # gets an error result (flag :error) and the rest of the batch goes on.
  def self.generate_safely(pin, features, options)
    parcels = options[:parcel_index]&.fetch(pin, nil)
    features += parcels if parcels && features.is_a?(Array)
    generate(pin, features, **options.except(:parcel_index))
  rescue StandardError => e
    Result.new(method_name: nil, pin: pin, flags: [:error], building: nil,
               explanation: [], steps: [],
               validation: Validation::Result.new(["error"], [], {}), provenance: { gem_version: VERSION })
          .prepend_step("generating this site failed: #{e.class}: #{e.message[0, 300]}", step: "error", flag: :error)
  end

  def self.check_data(data)
    unknown = data.keys - DATA_OPTIONS
    raise ArgumentError, "unknown data: option(s): #{unknown.join(", ")} (have: #{DATA_OPTIONS.join(", ")})" \
      if unknown.any?

    min_pins = data.fetch(:auto_build_min_pins, AUTO_BUILD_MIN_PINS)
    raise ArgumentError, "auto_build_min_pins must be a whole number from 1: #{min_pins.inspect}" \
      unless min_pins.is_a?(Integer) && min_pins >= 1
  end

  def self.fetch_and_generate(pins, source: nil, catalogue: nil, parquet: nil, cache_dir: nil, lookup: {}, data: {},
                              **options)
    check_data(data)
    check_generation_options(options)
    lookup = duckdb_options(lookup)
    return run_many(pins, catalogue, parquet, lookup, options) if catalogue || parquet

    source = (source || config.source).to_sym
    known = SOURCES.include?(source)
    raise ArgumentError, "unknown source #{source.inspect} (have: #{SOURCES.join(", ")})" unless known
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
      r.prepend_step("map data: OpenStreetMap, built from Geofabrik", step: "data")
    end
  end

  def self.merge(size, *parts)
    results = Array.new(size)
    parts.each { |indexes, list| indexes.zip(list).each { |i, r| results[i] = r } }
    results
  end

  # Overture reads bring its non-OSM (machine-learned) buildings with them,
  # so unless buildings: is given (directly or by the preset) they're used
  # where OSM has no building near the pin (:osm_or_ml); every site with an
  # OSM building comes out exactly as with :osm.
  def self.overture_options(options)
    given = options.key?(:buildings) || preset_options(options[:preset]).key?(:buildings)
    given ? options : options.merge(buildings: :osm_or_ml)
  end

  # The release is settled once up front, so every result names the one
  # it was read from.
  def self.from_overture(pins, lookup, data, options)
    online!("reading Overture Maps (use a catalogue or cached builds)")
    options = overture_options(options)
    release = Overture.release(data)
    lists = Overture.features_many(pins, **lookup.slice(:duckdb, :extension_directory, :radius_deg), release: release)
    pins.zip(lists).map do |pin, features|
      generate_safely(pin, features, options).tap do |r|
        r.provenance[:data] = { source: "overture", release: release }
        r.attribution = Overture.attribution(r.features)
        r.prepend_step("map data: OpenStreetMap, read from Overture Maps", step: "data")
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

  # The threads' values once every one has finished, then the first error
  # if any thread failed: callers may delete what the others are using.
  def self.join_all(threads)
    outcomes = threads.map do |thread|
      thread.value
    rescue StandardError => e
      e
    end
    error = outcomes.find { |o| o.is_a?(StandardError) }
    raise error if error

    outcomes
  end

  # Readers never see a half-written file, even with several processes
  # sharing a folder: written under a unique name, then renamed into place.
  def self.write_atomically(file, data)
    part = "#{file}.#{Process.pid}.#{Thread.current.object_id}.part"
    File.binwrite(part, data)
    File.rename(part, file)
  end

  def self.preset_options(preset)
    return {} if preset.nil?

    PRESETS.fetch(preset) do
      raise ArgumentError, "unknown preset #{preset.inspect} (have: #{PRESETS.keys.join(", ")})"
    end.dup
  end

  def self.generate_one(pin, features, files, catalogue, options)
    result = generate_safely(pin, features, options)
    result.provenance[:data] = if files.empty? then nil
                               elsif catalogue then catalogue.provenance(files)
                               else { source: "parquet" }
                               end
    credits = catalogue&.attribution(files) || []
    result.attribution = credits unless credits.empty?
    if files.empty?
      no_data(result)
    elsif catalogue && catalogue.coverage(pin) == :partial
      partial_data(result)
    end
    result
  end

  def self.partial_data(result)
    result.flags << :partial_data
    result.prepend_step("part of the area around the pin is in a region that isn't built: " \
                        "buildings or roads there are missing", step: "data", flag: :partial_data)
  end

  def self.no_data(result)
    result.flags << :no_data
    result.prepend_step("no map data covers this pin", step: "data", flag: :no_data)
  end

  private_class_method :fetch_and_generate, :with_parcels, :checked_pins, :check_data, :check_generation_options,
                       :generate_safely, :auto_plan, :build_and_read, :wait_quietly, :from_builds, :merge,
                       :from_overture, :overture_options, :run_many, :preset_options, :generate_one, :partial_data,
                       :no_data
end
