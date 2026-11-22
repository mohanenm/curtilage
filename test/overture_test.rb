# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Offline: checks the SQL Overture reads are built from, not the network.
class OvertureTest < Minitest::Test
  O = Curtilage::Overture
  BOX = [-80.004, 34.996, -79.996, 35.004].freeze
  FILES = ["s3://overturemaps-us-west-2/release/x/theme=buildings/type=building/part-1.parquet"].freeze

  def test_buildings_split_osm_from_other_sources
    assert_includes O.columns("building"),
                    "WHEN sources[1].dataset = 'OpenStreetMap' THEN 'building' ELSE 'ml_building'"
    assert_includes O.filter("building"), "NOT coalesce(is_underground, false)"
  end

  def test_segments_keep_ground_level_roads_and_rail
    assert_includes O.filter("segment"), "['is_tunnel', 'is_bridge']"
    assert_includes O.columns("segment"), "'standard_gauge' THEN 'rail'"
    assert_includes O.columns("segment"), "class || '_link'"
    refute_includes O.filter("segment"), "footway"
  end

  # Pins sharing files share one scan; rows go back to each pin by box.
  def test_pins_in_the_same_files_share_a_scan
    other = [-80.014, 34.996, -80.006, 35.004]
    files = { [0, "building"] => FILES, [1, "building"] => FILES }
    sql = O.data_sql([BOX, other], files, {})

    assert_equal 1, sql.scan("read_parquet").size
    assert_includes sql, "p.pin_index IN (0, 1)"
    assert_includes sql, "INSERT INTO boxes VALUES (0, -80.004"
  end

  def test_no_files_no_scan
    assert_equal "SELECT 1 WHERE false;", O.data_sql([BOX], {}, {})
  end

  def test_rejects_bad_pins
    assert_raises(ArgumentError) { O.box([200, 0], 0.004) }
  end

  def test_unknown_source
    assert_raises(ArgumentError) { Curtilage.generate_many([[-80.0, 35.0]], source: :bing) }
  end
end
