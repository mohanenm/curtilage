# frozen_string_literal: true

require_relative "test_helper"

# H3 covers through DuckDB's community extension; DuckDB is stubbed here
# (the integration test runs the real one where the extension exists).
class H3Test < Minitest::Test
  include SyntheticScene

  H3 = Curtilage::H3
  Status = Struct.new(:ok) do
    def success? = ok
  end

  def results = [Curtilage.generate(PIN, scene), Curtilage.generate(PIN, [])]

  def test_cover_sets_cells_on_results_with_premises
    seen = nil
    capture = lambda do |_duckdb, sql, *_args, **_opts|
      seen = sql
      [JSON.generate([{ i: 0, cells: %w[8b44a1 8b44a2] }]), "", Status.new(true)]
    end
    covered = with_stub(Curtilage::DuckDB, :capture, capture) { H3.cover(results, 11) }

    assert_equal({ resolution: 11, cells: %w[8b44a1 8b44a2] }, covered[0].h3)
    assert_nil covered[1].h3 # no premises
    assert_includes seen, "INSTALL h3 FROM community;"
    assert_includes seen, "'overlap'"
    assert_equal %w[8b44a1 8b44a2], covered[0].to_geojson[:properties][:h3][:cells]
    assert_equal "8b44a1;8b44a2", Curtilage::Formats.csv_row(covered[0], "a").last
  end

  def test_offline_only_loads_and_resolutions_are_checked
    Curtilage.configure { |c| c.offline = true }
    refute_includes H3.sql(["POLYGON((0 0, 1 0, 1 1, 0 0))"], 9, {}), "INSTALL"
  ensure
    Curtilage.configure { |c| c.offline = false }
  end

  def test_bad_resolution_and_missing_extension
    assert_raises(ArgumentError) { H3.cover(results, 16) }
    assert_raises(ArgumentError) { H3.cover(results, 9.5) }
    missing = ->(*, **) { ["", "HTTP Error: Failed to download extension \"h3\" (HTTP 404)", Status.new(false)] }
    # DuckDB.version is stubbed too: it caches what it finds, and a failed
    # stubbed call would make later tests think DuckDB is missing.
    error = with_stub(Curtilage::DuckDB, :version, ->(_) { "v2.0.1" }) do
      with_stub(Curtilage::DuckDB, :capture, missing) { assert_raises(Curtilage::DependencyError) { H3.cover(results, 9) } }
    end

    assert_match(/DuckDB 1.4/, error.message)
  end
end
