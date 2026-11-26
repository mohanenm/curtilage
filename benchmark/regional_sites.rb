# frozen_string_literal: true

# The regional check's sites: Overture places of the benchmark's types in a
# region, sorted into "clear" sites, whose pavement can be put down to the
# business, and "unclear" ones (benchmark/regional/README.md, "Choosing
# sites"). The tests run in DuckDB against the official layers.
module CurtilageBenchmark
  # region => the Geofabrik region whose outline bounds the places, and a
  # metric (UTM) projection for areas and distances.
  # box: places from this box instead of the Geofabrik region (a state too
  # big to read whole); only places near an official parcel are kept anyway.
  REGIONAL_AREAS = { "dc" => { geofabrik: "district-of-columbia", epsg: 32_618 },
                     "denver" => { geofabrik: "colorado", epsg: 32_613, box: DENVER_BOX },
                     "ct" => { geofabrik: "connecticut", epsg: 32_618 } }.freeze
  # The types the benchmark's random picks use.
  REGIONAL_TYPES = %w[pharmacy gas_station fast_food_restaurant grocery_store bank hotel hardware_store restaurant
                      coffee_shop post_office library department_store convenience_store].freeze
  # Every business, to tell whether a parcel holds only the site's.
  BUSINESS_CATEGORIES = %w[food_and_drink shopping health_care lodging services_and_business lifestyle_services
                           travel_and_transportation arts_and_entertainment sports_and_recreation].freeze
  REGIONAL_PIN_M = 5            # one official building at the pin, or within this
  REGIONAL_CANOPY_M = 15        # ... or this, from a pin on a fuel canopy (the gem's CANOPY_SHOP_M)
  REGIONAL_PARCEL_SHARE = 0.75  # the parcel holds at least this share of the building
  REGIONAL_MIN_PAVEMENT_M2 = 50 # the parcel's own parking and driveways
  HOLDOUT_CLEAR_M = 500         # nothing near a held-out site
  REGIONAL_COVERAGE_M = 50      # places with no official parcel this close are outside the data

  module_function

  # Writes sites.ndjson (the benchmark's types, confidence 0.9) and
  # businesses.ndjson (every business, confidence 0.7) into the region's
  # folder, from the pinned Overture release.
  def regional_places(region, dir: regional_dir(region))
    area = REGIONAL_AREAS.fetch(region)
    where = area[:box] ? { bbox: area[:box] } : { region: area[:geofabrik] }
    release = config.fetch("overture_release")
    find = lambda do |types, conf|
      types.flat_map { |t| Curtilage.places(**where, category: t, min_confidence: conf, release: release) }
    end
    found = { "sites" => find.call(REGIONAL_TYPES, 0.9), "businesses" => find.call(BUSINESS_CATEGORIES, 0.7) }
    found.each do |name, places|
      File.write(File.join(dir, "#{name}.ndjson"), places.uniq { |p| p[:id] }.map { |p| "#{place_row(p)}\n" }.join)
    end
  end

  def place_row(place)
    JSON.generate(id: place[:id], name: place[:name], category: place[:category], lng: place[:pin][0],
                  lat: place[:pin][1])
  end

  # Sorts the region's places into clear and unclear sites (selection.json),
  # leaving out every place within HOLDOUT_CLEAR_M of a held-out site.
  def select_regional_sites(region, dir: regional_dir(region))
    sql = regional_select_sql(region, dir, holdout_pins)
    _, err, status = Curtilage::DuckDB.capture(Curtilage.config.duckdb, sql)
    raise "DuckDB: #{err}" unless status.success?

    JSON.parse(File.read(File.join(dir, "selection.json"), encoding: "utf-8"))
  end

  # Always the public benchmark's held-out sites, whatever CURTILAGE_BENCHMARK_DIR says.
  def holdout_pins = sites(File.join(DIR, "sites.geojson")).select { |s| role(s) == "holdout" }.map { |s| s["pin"] }

  def regional_select_sql(region, dir, held)
    q = ->(name) { Curtilage::DuckDB.quote(File.join(dir, name)) }
    values = {
      setup: "#{extension_setup} #{Curtilage::DuckDB.load_sql("spatial")}",
      crs: "'EPSG:#{Integer(REGIONAL_AREAS.fetch(region)[:epsg])}'",
      layers: REGIONAL_LAYERS.fetch(region).map { |l| q.call("#{l[:name]}.ndjson") }.join(", "),
      sites: q.call("sites.ndjson"), businesses: q.call("businesses.ndjson"), out: q.call("selection.json"),
      held: held.empty? ? "(0.0, 0.0)" : held.map { |lng, lat| "(#{Float(lng)}, #{Float(lat)})" }.join(", "),
      pin_m: REGIONAL_PIN_M, canopy_m: REGIONAL_CANOPY_M, parcel_share: REGIONAL_PARCEL_SHARE,
      pavement_m2: REGIONAL_MIN_PAVEMENT_M2, holdout_m: HOLDOUT_CLEAR_M, coverage_m: REGIONAL_COVERAGE_M
    }
    sql = File.read(File.join(DIR, "regional", "select.sql"))
    sql.gsub(/\{\{(\w+)\}\}/) { values.fetch(Regexp.last_match(1).to_sym).to_s }
  end

  def extension_setup
    dir = Curtilage.config.extension_directory
    dir ? Curtilage::DuckDB.extension_sql(dir, Curtilage.config.duckdb) : ""
  end
end
