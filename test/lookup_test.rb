# frozen_string_literal: true

require_relative "test_helper"

class LookupTest < Minitest::Test
  L = Curtilage::Lookup

  def test_sql_filters_on_the_bounding_box_and_quotes_paths
    sql = L.sql("/tmp/it's.parquet", [-80.0, 35.0], "/ext", 0.004)

    assert_includes sql, "read_parquet('/tmp/it''s.parquet')"
    assert_includes sql, "SET extension_directory = '/ext';"
    assert_includes sql, "max_lng >= -80.004"
    assert_includes sql, "min_lat <= 35.004"
  end

  def test_rejects_bad_pins_and_radius
    assert_raises(ArgumentError) { L.sql("x", [-80.0, 135.0], nil, 0.004) }
    assert_raises(ArgumentError) { L.sql("x", ["1; DROP", 35.0], nil, 0.004) }
    assert_raises(ArgumentError) { L.sql("x", [-80.0, 35.0], nil, 1) }
  end

  def test_missing_parquet_file
    assert_raises(ArgumentError) { L.features(parquet: "/nonexistent.parquet", pin: [-80.0, 35.0]) }
  end
end
