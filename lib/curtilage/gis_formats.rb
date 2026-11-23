# frozen_string_literal: true

require "fileutils"

module Curtilage
  # Binary GIS outputs, written through DuckDB from the NDJSON a run
  # streams (so --resume works for them too): GeoParquet for analytics,
  # GeoPackage for QGIS and desktop GIS, FlatGeobuf for the web. One row a
  # site: the premises as the geometry, the store zone as WKT, and the
  # facts, attribution and provenance as columns. FlatGeobuf, for web maps,
  # holds only the sites with premises: its spatial index can't take an
  # empty geometry, and readers (DuckDB's among them) stumble on one.
  module GisFormats
    FORMATS = %i[geoparquet gpkg fgb].freeze
    COPY = {
      geoparquet: "(FORMAT parquet)",
      gpkg: "(FORMAT GDAL, DRIVER 'GPKG', SRS 'EPSG:4326')",
      fgb: "(FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:4326')",
    }.freeze
    EXTENSIONS = { ".parquet" => :geoparquet, ".geoparquet" => :geoparquet, ".gpkg" => :gpkg, ".fgb" => :fgb }.freeze
    MAX_LINE_BYTES = 64_000_000

    module_function

    def format_of(path) = EXTENSIONS[File.extname(path.to_s).downcase]

    # Writes out (via a file beside it, renamed at the end) from the NDJSON
    # file ndjson. options: duckdb, extension_directory.
    def convert(ndjson, out, format, **options)
      options = Curtilage.duckdb_options(options)
      temp = temp_path(out)
      FileUtils.rm_f(temp)
      duckdb = options.fetch(:duckdb, "duckdb")
      sql = [(DuckDB.extension_sql(options[:extension_directory], duckdb) if options[:extension_directory]),
             DuckDB.load_sql("spatial"), axis_order(duckdb), copy_sql(ndjson, temp, format)].compact.join("\n")
      _, err, status = DuckDB.capture(duckdb, sql)
      raise Error, "writing #{format} failed: #{DuckDB.clean(err).strip[0, 500]}" unless status.success?

      File.rename(temp, out)
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end

    # Beside out, keeping its extension: GDAL picks the layout from it
    # (FlatGeobuf writes a folder for any other name).
    def temp_path(out)
      ext = File.extname(out)
      File.join(File.dirname(File.expand_path(out)), ".#{File.basename(out, ext)}.writing#{ext}")
    end

    # DuckDB 2.0 won't hand GDAL an SRS until told its coordinates are
    # [lng, lat]; 1.4 has no such setting (and always passes them so).
    def axis_order(duckdb)
      major = DuckDB.version(duckdb).to_s[/v?(\d+)\./, 1].to_i
      "SET geometry_always_xy = true;" if major >= 2
    end

    # JSON is read as text and picked apart with json_extract, so sites with
    # different properties (data from Overture or Geofabrik) don't trip
    # DuckDB's schema inference.
    def copy_sql(ndjson, out, format)
      text = ->(path) { "json_extract_string(properties, '#{path}')" }
      columns = [
        "#{text.call("$.id")} AS id", "#{text.call("$.ok")}::BOOLEAN AS ok", "#{text.call("$.method")} AS method",
        "array_to_string(json_extract_string(properties, '$.flags[*]'), ';') AS flags",
        "#{text.call("$.confidence")}::DOUBLE AS confidence", "#{text.call("$.building")} AS building",
        "#{text.call("$.metrics.area_m2")}::DOUBLE AS area_m2",
        "array_to_string(json_extract_string(properties, '$.attribution[*]'), '; ') AS attribution",
        "#{text.call("$.provenance.gem_version")} AS gem_version",
        "#{text.call("$.provenance.data.source")} AS data_source",
        "#{text.call("$.provenance.features_sha256")} AS features_sha256",
        "json_extract(properties, '$.provenance')::VARCHAR AS provenance",
        "CASE WHEN json_type(json_extract(properties, '$.store')) = 'OBJECT' " \
        "THEN ST_AsText(ST_GeomFromGeoJSON(json_extract(properties, '$.store'))) END AS store_wkt",
        "CASE WHEN json_type(geometry) = 'OBJECT' THEN ST_GeomFromGeoJSON(geometry) END AS geometry"
      ]
      "COPY (SELECT #{columns.join(", ")} FROM read_json(#{DuckDB.quote(ndjson)}, " \
        "format = 'newline_delimited', columns = {properties: 'JSON', geometry: 'JSON'}, " \
        "maximum_object_size = #{MAX_LINE_BYTES})#{" WHERE json_type(geometry) = 'OBJECT'" if format == :fgb}) " \
        "TO #{DuckDB.quote(out)} #{COPY.fetch(format)};"
    end
  end
end
