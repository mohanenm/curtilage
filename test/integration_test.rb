# frozen_string_literal: true

require_relative "test_helper"
require_relative "fixtures/make_fixture"
require "tmpdir"

# End to end through the real DuckDB CLI, on a made-up region. Skipped when
# no DuckDB is installed, unless CURTILAGE_INTEGRATION=1 (as in CI), which
# makes a missing DuckDB a failure instead.
class IntegrationTest < Minitest::Test
  PIN = CurtilageFixture::PIN

  def setup
    return if Curtilage::DuckDB.version(Curtilage.config.duckdb)

    flunk "CURTILAGE_INTEGRATION is set but DuckDB can't run" if ENV["CURTILAGE_INTEGRATION"] == "1"
    skip "no DuckDB CLI: integration tests skipped"
  end

  def with_region
    Dir.mktmpdir do |dir|
      CurtilageFixture.write(dir)
      yield dir
    end
  end

  # GeoParquet parcels (a WKB geometry column) are read near the pins only
  # and clip the premises.
  def test_parquet_parcels_clip_the_premises
    with_region do |dir|
      parcels = File.join(dir, "parcels.parquet")
      near = CurtilageFixture.box(-50, -35, 20, 30)
      far = CurtilageFixture.box(5_000, 5_000, 5_050, 5_050)
      sql = [Curtilage::DuckDB.load_sql("spatial"),
             "COPY (SELECT ST_AsWKB(ST_GeomFromText(wkt)) AS geometry FROM (VALUES ('#{near}'), ('#{far}')) t(wkt)) " \
             "TO '#{parcels}' (FORMAT parquet);"]
      extensions = Curtilage.config.extension_directory
      sql.unshift(Curtilage::DuckDB.extension_sql(extensions, Curtilage.config.duckdb)) if extensions
      _, err, status = Curtilage::DuckDB.capture(Curtilage.config.duckdb, sql.join("\n"))
      assert status.success?, err

      assert_equal 1, Curtilage::Parcels.near(parcels, [PIN])[PIN].size
      result = Curtilage.generate_many([PIN], parquet: File.join(dir, "fixture.parquet"), parcels: parcels).first

      assert(result.steps.any? { |s| s[:step] == "clip_parcel" })
    end
  end

  # GeoParquet, GeoPackage and FlatGeobuf: written from the streamed NDJSON,
  # read back with DuckDB; attribution and provenance travel along.
  def test_gis_formats_round_trip
    with_region do |dir|
      results = Curtilage.generate_many([PIN, [-79.0, 35.0]], parquet: File.join(dir, "fixture.parquet"))
      { geoparquet: "out.parquet", gpkg: "out.gpkg", fgb: "out.fgb" }.each do |format, name|
        out = File.join(dir, name)
        batch = Curtilage::Batch.new(format: format, out: out, duckdb: {})
        batch.add(results, %w[site-1 site-2])
        batch.finish

        rows = read_back(out, format)

        expected = format == :fgb ? %w[site-1] : %w[site-1 site-2] # FlatGeobuf: sites with premises only
        assert_equal expected, rows.map { |r| r["id"] }, format
        assert_equal ["POLYGON", nil].first(expected.size), rows.map { |r| r["kind"] }, format
        assert_includes rows[0]["attribution"], "OpenStreetMap", format
        assert_match(/gem_version/, rows[0]["provenance"].to_s, format)
        refute File.exist?(batch.part), "no .part left behind"
      end
    end
  end

  def read_back(path, format)
    from = format == :geoparquet ? "read_parquet(#{Curtilage::DuckDB.quote(path)})" : "ST_Read(#{Curtilage::DuckDB.quote(path)})"
    geom = format == :geoparquet ? "geometry" : "geom"
    sql = [Curtilage::DuckDB.load_sql("spatial"),
           "SELECT id, attribution, provenance, upper(ST_GeometryType(#{geom})::VARCHAR) AS kind " \
           "FROM #{from} ORDER BY id;"]
    extensions = Curtilage.config.extension_directory
    sql.unshift(Curtilage::DuckDB.extension_sql(extensions, Curtilage.config.duckdb)) if extensions
    out, err, status = Curtilage::DuckDB.capture(Curtilage.config.duckdb, sql.join("\n"), "-json")
    assert status.success?, err
    JSON.parse(out)
  end

  # The community h3 extension isn't published for every DuckDB release
  # (2.0.1 lacks it at the time of writing): skipped where it can't load.
  def test_h3_cover_with_the_real_extension
    with_region do |dir|
      results = Curtilage.generate_many([PIN], parquet: File.join(dir, "fixture.parquet"))
      begin
        Curtilage::H3.cover(results, 11)
      rescue Curtilage::DependencyError => e
        skip e.message
      end

      cells = results[0].h3[:cells]

      assert_operator cells.size, :>=, 2 # a ~70 x 80 m lot spans several 25 m cells
      assert(cells.all? { |c| c.match?(/\A8b[0-9a-f]{13}\z/) })
    end
  end

  def test_lookup_reads_the_features_around_a_pin
    with_region do |dir|
      rows = Curtilage::Lookup.features(parquet: File.join(dir, "fixture.parquet"), pin: PIN)

      assert_equal %w[building building parking road], rows.map { |r| r["feature"] }.sort
      assert_equal "Polygon", rows.find { |r| r["id"] == 1 }["geometry"]["type"]
    end
  end

  def test_generate_many_from_a_catalogue_end_to_end
    with_region do |dir|
      catalogue = Curtilage::Catalogue.from_dir(dir)
      results = Curtilage.generate_many([PIN, [-79.0, 35.0]], catalogue: catalogue, keep_features: true)

      assert_predicate results[0], :ok?
      assert_equal :grow_trim, results[0].method_name
      assert_equal ["Made-up test data"], results[0].attribution
      assert_includes results[1].flags, :no_data
      assert_includes Curtilage::Preview.html(results), %(class="building site")
    end
  end

  def test_doctor_is_happy
    report = Curtilage::Doctor.report(Curtilage.duckdb_options)

    assert report["ok"], report.inspect
  end
end
