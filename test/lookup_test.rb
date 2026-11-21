# frozen_string_literal: true

require_relative "test_helper"

class LookupTest < Minitest::Test
  L = Curtilage::Lookup

  def test_sql_filters_each_pin_on_its_box_and_quotes_paths
    sql = L.sql(["/tmp/it's.parquet"], [[-80.0, 35.0], [-81.0, 36.0]], "/ext", 0.004)

    assert_includes sql, "read_parquet(['/tmp/it''s.parquet'])"
    assert_includes sql, "SET extension_directory = '/ext';"
    assert_includes sql, "SELECT 1 AS pin_index"
    assert_includes sql, "max_lng >= -80.004"
    assert_includes sql, "min_lat <= 36.004"
    refute_includes sql, "httpfs"
  end

  def test_remote_files_load_httpfs_and_setup_sql_goes_in_the_script
    sql = L.sql(["s3://bucket/tennessee.parquet"], [[-80.0, 35.0]], nil, 0.004, "CREATE SECRET (TYPE s3);")

    assert_includes sql, "LOAD httpfs;"
    assert_includes sql, "CREATE SECRET (TYPE s3);"
  end

  def test_rejects_bad_pins_and_radius
    assert_raises(ArgumentError) { L.sql(["x"], [[-80.0, 135.0]], nil, 0.004) }
    assert_raises(ArgumentError) { L.sql(["x"], [["1; DROP", 35.0]], nil, 0.004) }
    assert_raises(ArgumentError) { L.sql(["x"], [[-80.0, 35.0]], nil, 1) }
  end

  def test_missing_parquet_file
    assert_raises(ArgumentError) { L.features(parquet: "/nonexistent.parquet", pin: [-80.0, 35.0]) }
    assert_raises(ArgumentError) { L.features(parquet: [], pin: [-80.0, 35.0]) }
  end

  def test_groups_rows_by_pin
    out = JSON.generate([{ "pin_index" => 1, "id" => 5, "geometry" => '{"type":"Point","coordinates":[0,0]}' }])
    lists = L.group(out, 2)

    assert_empty lists[0]
    assert_equal 5, lists[1].first["id"]
  end
end
