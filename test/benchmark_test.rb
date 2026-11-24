# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"
require_relative "../benchmark/check_sites"
require "tmpdir"

# Offline: the benchmark's scoring, summary, cache and comparison, on
# made-up sites and fake results.
class BenchmarkTest < Minitest::Test
  include SyntheticScene

  B = CurtilageBenchmark
  FakeResult = Struct.new(:ring, :ok, :method_name, :flags, :validation) do
    def ok? = ok
  end

  # A 100 m square around the pin, as [lng, lat], closed.
  def square(half = 50)
    [[-half, -half], [half, -half], [half, half], [-half, half], [-half, -half]].map { |x, y| lnglat(x, y) }
  end

  def fake(ring, flags: [])
    FakeResult.new(ring, !ring.nil?, :grow_trim, flags, Curtilage::Validation.check(PIN, ring))
  end

  def site(id, category: "standalone", placeholder: false)
    { "id" => id, "category" => category, "placeholder" => placeholder, "pin" => PIN }
  end

  # An L-shaped reference (the square minus its north-east quarter) scores
  # 7,500 / 10,000 against the square.
  def test_scores_against_a_non_convex_reference
    l_shape = [[-50, -50], [50, -50], [50, 0], [0, 0], [0, 50], [-50, 50], [-50, -50]].map { |x, y| lnglat(x, y) }
    row = B.score(site("a"), fake(square), l_shape)

    assert_in_delta 0.75, row["iou"], 0.002
    assert_in_delta 1.33, row["area_ratio"], 0.01
    assert_in_delta 7_500, row["reference_area_m2"], 10
    assert_equal 0.0, B.score(site("b"), fake(nil), l_shape)["iou"]
    refute B.score(site("c"), fake(square), nil).key?("iou")
  end

  def test_placeholders_stay_out_of_the_totals
    rows = [B.score(site("a"), fake(square, flags: [:fallback]), square),
            B.score(site("b", category: "big_box"), fake(nil), square),
            B.score(site("p", placeholder: true), fake(square), square)]
    summary = B.summary(rows)

    assert_equal 2, summary["all"]["sites"]
    assert_equal 1, summary["all"]["valid"]
    assert_equal 1, summary["all"]["fallbacks"]
    assert_equal({ "fallback" => 1 }, summary["all"]["flags"])
    assert_equal %w[big_box standalone], summary["categories"].keys
    assert_equal 1, summary["placeholders"]["sites"]
  end

  # The smallest parcel containing the pin, from Polygon or MultiPolygon
  # parts; geometry only is kept from a server's answer.
  def test_parcel_is_the_smallest_containing_the_pin
    ring = lambda { |half, dx = 0|
      [[-half + dx, -half], [half + dx, -half], [half + dx, half], [-half + dx, half],
       [-half + dx, -half]].map do |x, y|
        lnglat(x, y)
      end
    }
    doc = { "features" => [{ "geometry" => { "type" => "Polygon", "coordinates" => [ring.call(80)] } },
                           { "geometry" => { "type" => "MultiPolygon",
                                             "coordinates" => [[ring.call(5, 300)], [ring.call(40)]] } }] }
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.geojson"), JSON.generate(doc))

      assert_equal ring.call(40), B.parcel("a", PIN, dir)
      assert_nil B.parcel("missing", PIN, dir)
    end
  end

  def test_held_out_sites_are_scored_only_on_request
    sites = [site("a"), site("h").merge("holdout" => true)]

    assert_equal(["a"], B.scored_sites(sites).map { |s| s["id"] })
    ENV["CURTILAGE_BENCHMARK_HOLDOUT"] = "1"
    assert_equal(["h"], B.scored_sites(sites).map { |s| s["id"] })
  ensure
    ENV.delete("CURTILAGE_BENCHMARK_HOLDOUT")
  end

  def test_features_are_fetched_once_then_cached
    Dir.mktmpdir do |dir|
      calls = []
      fetch = lambda do |pins|
        calls << pins
        pins.map { scene }
      end
      sites = [site("a"), site("b")]
      2.times { B.features(sites, "test-release", cache: dir, fetch: fetch) }
      moved = [site("a").merge("pin" => [-80.001, 35.0]), site("b")]
      B.features(moved, "test-release", cache: dir, fetch: fetch)

      assert_equal [[PIN, PIN], [[-80.001, 35.0]]], calls
    end
  end

  def test_runs_sites_and_compares_runs
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.geojson"),
                 JSON.generate(type: "Feature", geometry: { type: "Polygon", coordinates: [square(40)] }))
      config = { "overture_release" => "test", "options" => {} }
      sites = [site("a"), site("b", category: "big_box").merge("options" => { "preset" => "tight" })]
      run = B.run(sites: sites, features: { "a" => scene, "b" => scene }, references: dir, config: config)

      assert_equal 2, run["summary"]["all"]["valid"]
      assert run["sites"].first["iou"].positive?
      assert_includes B.table(run), "ALL"
      refute B.numbers_only(run)["sites"].first.key?("ring")

      worse = JSON.parse(JSON.generate(run))
      worse["sites"].first.merge!("ok" => false, "iou" => 0.0, "flags" => ["fallback"])
      changes = B.compare(run, worse)

      assert_includes changes, "a: ok true -> false"
      assert_includes changes, "flags +fallback"
      refute_includes changes, "b:"
    end
  end

  def test_sites_need_safe_ids
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sites.geojson")
      File.write(path, JSON.generate(type: "FeatureCollection", features: [
                                       { type: "Feature", geometry: { type: "Point", coordinates: PIN },
                                         properties: { id: "../escape" } },
                                     ]))
      assert_raises(ArgumentError) { B.sites(path) }
    end
  end

  def test_the_shipped_sites_and_references_load
    sites = B.sites

    refute_empty sites
    sites.each { |s| assert_kind_of Array, B.reference(s["id"]) if s["placeholder"] }
  end

  def test_sites_near_private_ones_are_caught
    Dir.mktmpdir do |dir|
      path = File.join(dir, "private.json")
      File.write(path, JSON.generate(sites: [{ pin: lnglat(300, 0) }, { pin: [10.0, 50.0] }]))
      pins = B.private_pins(path)

      assert_equal [["a", 300]], B.too_close([site("a")], pins)
      assert_empty B.too_close([site("a")], pins, min: 200)
    end
  end
end
