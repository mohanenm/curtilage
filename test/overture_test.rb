# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Offline: checks the SQL Overture reads are built from, not the network.
class OvertureTest < Minitest::Test
  O = Curtilage::Overture
  BOX = [-80.004, 34.996, -79.996, 35.004].freeze
  FILES = ["s3://overturemaps-us-west-2/release/x/theme=buildings/type=building/part-1.parquet"].freeze

  def test_buildings_split_osm_from_other_sources
    sql = O.buildings(0, BOX, FILES)

    assert_includes sql, "WHEN sources[1].dataset = 'OpenStreetMap' THEN 'building' ELSE 'ml_building'"
    assert_includes sql, "bbox.xmin <= -79.996"
    assert_includes sql, "NOT coalesce(is_underground, false)"
  end

  def test_segments_keep_ground_level_roads_and_rail
    sql = O.segments(1, BOX, FILES)

    assert_includes sql, "['is_tunnel', 'is_bridge']"
    assert_includes sql, "'standard_gauge' THEN 'rail'"
    assert_includes sql, "class || '_link'"
    refute_includes sql, "footway"
  end

  def test_no_files_no_scan
    assert_nil O.parking(0, BOX, [])
    assert_equal "SELECT 1 WHERE false;", O.data_sql([BOX], {}, {})
  end

  def test_rejects_bad_pins
    assert_raises(ArgumentError) { O.box([200, 0], 0.004) }
  end

  def test_groups_rows_by_pin
    rows = [{ "pin_index" => 0, "id" => "a", "geometry" => '{"type":"Point","coordinates":[0,0]}' }]

    assert_equal "a", O.group(rows, 2).first.first["id"]
  end

  def test_unknown_source
    assert_raises(ArgumentError) { Curtilage.generate_many([[-80.0, 35.0]], source: :bing) }
  end
end
