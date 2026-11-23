# frozen_string_literal: true

require "json"
require "curtilage"

# A tiny region built the way `curtilage build` builds one (same columns,
# same WKB encoding), from made-up geometry around [-80.0, 35.0]: a shop,
# its parking, a neighbour and a road. Nothing here is OpenStreetMap data.
module CurtilageFixture
  PIN = [-80.0, 35.0].freeze

  module_function

  # Rectangle [[x0, y0], [x1, y1]] in metres around PIN as WKT.
  def box(x0, y0, x1, y1)
    ring = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]
    "POLYGON((#{Curtilage::Geometry.unproject(ring, PIN).map { |lng, lat| "#{lng} #{lat}" }.join(", ")}))"
  end

  def line(points)
    "LINESTRING(#{Curtilage::Geometry.unproject(points, PIN).map { |lng, lat| "#{lng} #{lat}" }.join(", ")})"
  end

  FEATURES = [
    [1, "building", "retail", "Made-up Shop", box(-10, -7.5, 10, 7.5)],
    [2, "building", "commercial", nil, box(50, -10, 70, 10)],
    [3, "parking", nil, nil, box(-45, -20, -11, 20)],
    [4, "road", "secondary", "Example Road", line([[-200, -40], [200, -40]])],
  ].freeze

  # Writes fixture.parquet and its catalogue metadata into dir.
  def write(dir, duckdb: Curtilage.config.duckdb, extension_directory: Curtilage.config.extension_directory)
    rows = FEATURES.map { |id, kind, type, name, wkt| "(#{id}, #{q(kind)}, #{q(type)}, #{q(name)}, #{q(wkt)})" }
    out = File.join(dir, "fixture.parquet")
    sql = [(Curtilage::DuckDB.extension_sql(extension_directory, duckdb) if extension_directory),
           Curtilage::DuckDB.load_sql("spatial"),
           "COPY (SELECT id, feature, highway, name, ST_XMin(g) AS min_lng, ST_YMin(g) AS min_lat, " \
           "ST_XMax(g) AS max_lng, ST_YMax(g) AS max_lat, ST_AsWKB(g) AS wkb " \
           "FROM (SELECT *, ST_GeomFromText(wkt) AS g FROM (VALUES #{rows.join(", ")}) " \
           "t(id, feature, highway, name, wkt))) TO #{q(out)} (FORMAT parquet);"]
    _, err, status = Curtilage::DuckDB.capture(duckdb, sql.compact.join("\n"))
    raise Curtilage::Error, "fixture: #{err.strip}" unless status.success?

    File.write(File.join(dir, "fixture.json"),
               JSON.generate(format: 1, region: "test/fixture", parquet: "fixture.parquet",
                             bbox: [-80.01, 34.99, -79.99, 35.01], attribution: ["Made-up test data"]))
    out
  end

  def q(value) = value.nil? ? "NULL" : Curtilage::DuckDB.quote(value)
end
