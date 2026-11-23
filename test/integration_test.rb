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
