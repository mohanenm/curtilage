# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

class ZonesTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  def ring_xy(ring) = G.open_ring(G.project(ring, PIN))

  def holds?(outer, inner)
    o = ring_xy(outer)
    ring_xy(inner).all? { |p| G.contains?(o, p) || G.distance_to_edges(o, p) < 1e-6 }
  end

  def test_no_zones_unless_asked
    r = Curtilage.generate(PIN, scene)

    assert_nil r.approach_ring
    assert_nil r.pickup_ring
    assert_equal(%w[premises store], r.to_geojson(include_store: true)[:features].map { |f| f[:properties][:role] })
  end

  def test_zones_are_nested_at_any_precision
    [7, 5].each do |precision|
      r = Curtilage.generate(PIN, scene, approach_m: 150, pickup_m: 25, precision: precision)

      assert holds?(r.approach_ring, r.ring), "approach holds the premises (#{precision})"
      assert holds?(r.ring, r.pickup_ring), "premises hold the pickup zone (#{precision})"
      assert holds?(r.ring, r.store_ring)
      assert_operator ring_xy(r.approach_ring).size, :<=, Curtilage::Generator::MAX_APPROACH_VERTICES
    end
  end

  def test_the_approach_zone_reaches_out_about_that_far
    r = Curtilage.generate(PIN, scene, approach_m: 150)
    premises = ring_xy(r.ring)
    nearest_edge = ring_xy(r.approach_ring).map { |p| G.distance_to_edges(premises, p) }.min

    assert_in_delta 150, nearest_edge, 15
    assert_equal "approach_m", r.steps.find { |s| s[:step] == "approach_zone" }[:rule]
  end

  def test_the_pickup_zone_is_mapped_parking_by_the_building
    r = Curtilage.generate(PIN, scene, pickup_m: 25)
    parking = scene.find { |f| f["feature"] == "parking" }["geometry"]["coordinates"][0]

    assert(ring_xy(r.pickup_ring).all? do |p|
      G.contains?(ring_xy(parking), p) || G.distance_to_edges(ring_xy(parking), p) < 0.1
    end)
    assert_operator ring_xy(r.pickup_ring).map { |x, _| x }.min, :>=, -10 - 25 - 0.1 # within 25 m of the building
    step = r.steps.find { |s| s[:step] == "pickup_zone" }

    assert_equal [3], step[:features]
    pickup = r.to_geojson(include_store: true)[:features].find { |f| f[:properties][:role] == "pickup" }

    assert pickup[:properties][:estimated]
  end

  def test_the_staging_point_is_the_pickup_zone_point_nearest_the_building
    r = Curtilage.generate(PIN, scene, pickup_m: 25)
    x, y = G.project([r.staging_point], PIN).first

    assert_in_delta(-11, x, 0.2) # the parking's edge facing the building (10 m west of the pin, plus a 1 m aisle)
    assert G.contains?(ring_xy(r.ring), [x, y])
    assert_operator y.abs, :<=, 7.5
    assert_match(/\APOINT \(/, r.staging_wkt)
    assert_nil Curtilage.generate(PIN, scene).staging_point
  end

  def test_no_pickup_zone_without_parking_nearby
    r = Curtilage.generate(PIN, scene.reject { |f| f["feature"] == "parking" }, pickup_m: 25)

    assert_nil r.pickup_ring
    assert_includes r.explanation, "no pickup zone: no mapped parking within 25 m of the building"
  end

  def test_zones_in_every_output
    results = [Curtilage.generate(PIN, scene, approach_m: 100, pickup_m: 25)]
    line = JSON.parse(Curtilage::Formats.write(results, :ndjson))
    roles = JSON.parse(Curtilage::Formats.write(results, :geojson))["features"].map { |f| f["properties"]["role"] }
    row = Curtilage::Formats.parse_csv(Curtilage::Formats.write(results, :csv))[1]

    assert_equal %w[Polygon Polygon], [line["properties"]["approach"]["type"], line["properties"]["pickup"]["type"]]
    assert_equal %w[premises store approach pickup staging], roles
    assert_match(/\APOLYGON/, row[Curtilage::Formats::CSV_COLUMNS.index("pickup_wkt")])
    assert_includes Curtilage::Formats.write(results, :kml), "1 pickup (estimated)"
    assert_includes Curtilage::Preview.html(results), %(class="pickup")
  end

  def test_zone_options_are_checked
    assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, approach_m: -5) }
    assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, pickup_m: 5_000) }
  end

  def test_cli_flags_default_their_distances
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      out, = Open3.capture3("ruby", "-I", lib, exe, "generate", "--pin", "-80,35", "--parquet",
                            File.join(dir, "region.parquet"), "--duckdb", fake, "--format", "ndjson",
                            "--approach", "--pickup", "10")
      options = JSON.parse(out.force_encoding(Encoding::UTF_8))["properties"]["provenance"]["options"]

      assert_equal [150, 10.0], options.values_at("approach_m", "pickup_m")
    end
  end
end
