# frozen_string_literal: true

require "json"

module Curtilage
  # Property lines the caller supplies (generate_many parcels:): a GeoJSON
  # file of Polygons or MultiPolygons, or Parquet (GeoParquet: a WKB
  # geometry column; a local path or a URL DuckDB can read, with
  # setup_sql: for a private bucket). Read once per call, only near the
  # pins, and never fetched by curtilage on its own: the caller chooses the
  # data and answers for its licence. Each pin's parcels join its map data
  # as "parcel" features (see Generator's clip_to_parcel).
  module Parcels
    MAX_GEOJSON_BYTES = 100_000_000
    RADIUS_DEG = Lookup::DEFAULT_RADIUS_DEG

    module_function

    # { pin => [parcel features] } for the given pins.
    def near(source, pins, lookup = {})
      parquet = source.to_s.downcase.end_with?(".parquet")
      pins.zip(parquet ? from_parquet(source, pins, lookup) : from_geojson(source, pins)).to_h
    end

    def from_geojson(path, pins)
      raise ArgumentError, "parcels file not found: #{path}" unless File.file?(path.to_s)
      raise ArgumentError, "parcels file is over #{MAX_GEOJSON_BYTES} bytes" if File.size(path) > MAX_GEOJSON_BYTES

      doc = JSON.parse(File.read(path, encoding: "utf-8"))
      list = doc.is_a?(Hash) && doc["features"].is_a?(Array) ? doc["features"] : nil
      raise ArgumentError, "parcels must be a GeoJSON FeatureCollection" unless list

      parcels = list.filter_map { |f| parcel(f) }
      pins.map { |pin| parcels.select { |_, box| near?(box, pin) }.map(&:first) }
    rescue JSON::ParserError => e
      raise ArgumentError, "parcels file isn't valid JSON: #{e.message[0, 200]}"
    end

    # [parcel feature, [min_lng, min_lat, max_lng, max_lat]], or nil for
    # anything that isn't a polygon with numeric corners.
    def parcel(feature)
      geometry = feature.is_a?(Hash) ? feature["geometry"] : nil
      return nil unless geometry.is_a?(Hash) && %w[Polygon MultiPolygon].include?(geometry["type"])

      coords = Array(geometry["coordinates"])
      rings = geometry["type"] == "Polygon" ? [coords.first] : coords.map { |poly| Array(poly).first }
      points = rings.flat_map { |r| r.is_a?(Array) ? r : [] }
      return nil if points.empty? || !Geometry.valid_coordinates?(points)

      id = feature["id"] || feature.dig("properties", "id")
      [{ "feature" => "parcel", "id" => id, "geometry" => geometry }, Geometry.bounds(points)]
    end

    def near?(box, pin)
      lng, lat = pin
      box[2] >= lng - RADIUS_DEG && box[0] <= lng + RADIUS_DEG &&
        box[3] >= lat - RADIUS_DEG && box[1] <= lat + RADIUS_DEG
    end

    def from_parquet(source, pins, lookup)
      options = Curtilage.duckdb_options(lookup)
      Lookup.check_files([source])
      sql = [Lookup.setup([source], options[:extension_directory], options[:setup_sql],
                          options.fetch(:duckdb, "duckdb"), options.fetch(:memory_limit, Lookup::DEFAULT_MEMORY)),
             query(source, pins)].join("\n")
      out, err, status = DuckDB.capture(options.fetch(:duckdb, "duckdb"), sql, "-json",
                                        timeout: options.fetch(:timeout, Curtilage.config.duckdb_timeout),
                                        max_output: Lookup::MAX_OUTPUT_BYTES)
      raise Lookup::Error, "duckdb failed reading parcels: #{err.strip[0, 500]}" unless status.success?

      Lookup.group(out, pins.size)
    end

    def query(source, pins)
      rows = pins.each_with_index.map do |pin, i|
        lng, lat = Validation.pin(pin)
        "(#{i}, #{lng - RADIUS_DEG}, #{lat - RADIUS_DEG}, #{lng + RADIUS_DEG}, #{lat + RADIUS_DEG})"
      end
      "CREATE TEMP TABLE boxes (pin_index INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE); " \
        "INSERT INTO boxes VALUES #{rows.join(", ")};\n" \
        "SELECT b.pin_index, 'parcel' AS feature, ST_AsGeoJSON(p.geometry::GEOMETRY)::VARCHAR AS geometry " \
        "FROM read_parquet(#{DuckDB.quote(source)}) p JOIN boxes b " \
        "ON ST_Intersects(p.geometry::GEOMETRY, ST_MakeEnvelope(b.x0, b.y0, b.x1, b.y1));"
    end
  end
end
