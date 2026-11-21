# frozen_string_literal: true

require "json"
require "open3"

module Curtilage
  # Reads the features around a pin from a features Parquet file (built by
  # sql/build_from_shapefiles.sql) with the DuckDB CLI. Shelling out keeps the
  # gem free of native dependencies; only the row groups near the pin are read.
  module Lookup
    class Error < StandardError; end

    # About 400 m north-south and 450 m east-west at US latitudes: room for
    # the lot and its bounding roads.
    DEFAULT_RADIUS_DEG = 0.004
    MAX_OUTPUT_BYTES = 50_000_000

    module_function

    # Returns feature hashes for Features.new / Curtilage.generate.
    # duckdb: path to the CLI. extension_directory: where the spatial
    # extension lives (must be absolute on macOS).
    def features(parquet:, pin:, duckdb: "duckdb", extension_directory: nil, radius_deg: DEFAULT_RADIUS_DEG)
      raise ArgumentError, "parquet file not found: #{parquet}" unless File.file?(parquet)

      out, err, status = Open3.capture3(duckdb, "-json", "-c", sql(parquet, pin, extension_directory, radius_deg))
      raise Error, "duckdb failed: #{err.strip[0, 500]}" unless status.success?
      raise Error, "duckdb output too large" if out.bytesize > MAX_OUTPUT_BYTES

      rows = out.strip.empty? ? [] : JSON.parse(out)
      rows.map { |row| row.merge("geometry" => JSON.parse(row["geometry"])) }
    end

    def sql(parquet, pin, extension_directory, radius_deg)
      lng = Float(pin[0])
      lat = Float(pin[1])
      r = Float(radius_deg)
      raise ArgumentError, "pin out of range" unless lng.abs <= 180 && lat.abs <= 90 && r.positive? && r <= 0.05

      setup = extension_directory ? "SET extension_directory = #{quote(extension_directory)}; " : ""
      <<~SQL.tr("\n", " ")
        #{setup}LOAD spatial;
        SELECT id, feature, highway, name, ST_AsGeoJSON(wkb)::VARCHAR AS geometry
        FROM read_parquet(#{quote(parquet)})
        WHERE max_lng >= #{lng - r} AND min_lng <= #{lng + r}
          AND max_lat >= #{lat - r} AND min_lat <= #{lat + r};
      SQL
    end

    def quote(text)
      "'#{text.to_s.gsub("'", "''")}'"
    end
  end
end
