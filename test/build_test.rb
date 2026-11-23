# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class BuildTest < Minitest::Test
  B = Curtilage::Build
  SETTINGS = { memory_limit: "400MB", threads: 1, temp_directory: "/tmp/x", extension_directory: nil }.freeze

  def with_layers(parts)
    Dir.mktmpdir do |dir|
      dirs = parts.map.with_index do |files, i|
        d = File.join(dir, "part#{i}")
        FileUtils.mkdir_p(d)
        files.each { |f| FileUtils.touch(File.join(d, f)) }
        d
      end
      yield dirs
    end
  end

  def test_sql_reads_every_part_of_every_layer
    base = %w[gis_osm_buildings_a_free_1.shp gis_osm_traffic_a_free_1.shp gis_osm_roads_free_1.shp
              gis_osm_railways_free_1.shp]
    with_layers([base + ["gis_osm_buildings_a_free_2.shp"], base]) do |dirs|
      sql = B.sql(dirs, "/out/it's.parquet", SETTINGS)

      assert_equal 3, sql[/CREATE VIEW buildings_a_src AS [^;]*;/].scan("ST_Read").size
      assert_equal 2, sql[/CREATE VIEW railways_src AS [^;]*;/].scan("ST_Read").size
      assert_includes sql, "SET VARIABLE out_path = '/out/it''s.parquet';"
      assert_includes sql, "SET memory_limit = '400MB';"
      assert_includes sql, "COPY ("
      assert_includes sql, "CREATE VIEW ml_buildings_src"
    end
  end

  def test_missing_layer_is_an_error
    with_layers([%w[gis_osm_buildings_a_free_1.shp]]) do |dirs|
      assert_raises(B::Error) { B.sql(dirs, "/out.parquet", SETTINGS) }
    end
  end

  def test_region_paths
    assert_equal "north-america/us/tennessee", B.region_path("tennessee")
    assert_equal "europe/germany/bayern", B.region_path("europe/germany/bayern")
    ["../etc", "Tennessee", "new york", "", "us//x", "/abs"].each do |name|
      assert_raises(ArgumentError) { B.region_path(name) }
    end
  end

  def test_rejects_unknown_footprint_source
    assert_raises(ArgumentError) { B.run("tennessee", out_dir: "/x", work_dir: "/x", ml_footprints: "acme") }
  end

  def test_metadata
    rows = [{ "feature" => "building", "n" => 5, "a" => -81, "b" => 34, "c" => -80, "d" => 35 },
            { "feature" => "road", "n" => 2, "a" => -82, "b" => 33.5, "c" => -79.5, "d" => 35 }]
    meta = B.metadata("/x/tennessee.parquet", "north-america/us/tennessee", %w[261119], rows, ml_footprints: nil)

    assert_equal [-82, 33.5, -79.5, 35], meta[:bbox]
    assert_equal({ "building" => 5, "road" => 2 }, meta[:counts])
    assert_equal ["2026-11-19"], meta[:source_dates]
    assert_equal ["© OpenStreetMap contributors"], meta[:attribution]
  end

  def test_multi_part_regions
    assert_equal 2, B::PARTS["north-america/us/california"].size
  end

  def test_ml_view
    assert_includes B.ml_view([], nil), "WHERE false"
    view = B.ml_view(["/t/a.csv.gz"], [-81, 34, -80, 35])

    assert_includes view, "read_json(['/t/a.csv.gz']"
    assert_includes view, "ST_MakeEnvelope(-81.0, 34.0, -80.0, 35.0)"
  end

  def test_bad_date_is_refused_before_any_download
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) do
        Curtilage::Build.run("delaware", out_dir: dir, work_dir: dir, date: "../../x", log: StringIO.new)
      end
    end
  end

  def test_sources_record_each_layer_file_and_spot_upstream_changes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "gis_osm_roads_free_1.shp"), "roads")
      File.write(File.join(dir, "gis_osm_roads_free_1.dbf"), "attributes")
      File.write(File.join(dir, "notes.txt"), "not a layer")
      source = B.source_record("north-america/us/delaware", "261121", dir)

      assert_equal "delaware-261121-free.shp.zip", source["file"]
      assert_equal %w[gis_osm_roads_free_1.dbf gis_osm_roads_free_1.shp], source["members"].keys
      assert_equal Digest::SHA256.hexdigest("roads"), source["members"]["gis_osm_roads_free_1.shp"]["sha256"]
      previous = JSON.parse(JSON.generate(sources: [source]))

      assert_empty B.upstream_changes(previous, [source])
      altered = JSON.parse(JSON.generate(source))
      altered["members"]["gis_osm_roads_free_1.shp"]["sha256"] = "0" * 64

      assert_equal ["delaware-261121-free.shp.zip"], B.upstream_changes(previous, [altered])
      assert_empty B.upstream_changes(nil, [altered])
      other_day = altered.merge("file" => "delaware-261122-free.shp.zip")
      assert_empty B.upstream_changes(previous, [other_day])
    end
  end
end
