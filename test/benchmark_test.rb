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

  # Every outer ring around the site becomes a "parcel" feature for the gem.
  def test_area_parcels_become_parcel_features
    square = ->(x) { [[x, 0], [x + 10, 0], [x + 10, 10], [x, 10], [x, 0]].map { |a, b| lnglat(a, b) } }
    doc = { "features" => [{ "geometry" => { "type" => "Polygon", "coordinates" => [square.call(0)] } },
                           { "geometry" => { "type" => "MultiPolygon",
                                             "coordinates" => [[square.call(20)], [square.call(40)]] } },
                           { "geometry" => nil }] }
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.geojson"), JSON.generate(doc))
      parcels = B.area_parcel_features("a", dir)

      assert_equal 3, parcels.size
      assert(parcels.all? { |f| f["feature"] == "parcel" })
      assert_empty B.area_parcel_features("missing", dir)
    end
  end

  # Each held-out set is reported beside the combined held-out group.
  # Each held-out set is reported beside the combined group, but only when
  # every set is big enough that its totals can't show one site's result.
  def test_role_groups_split_held_out_sets_of_five_or_more
    held = ->(set, n) { (1..n).map { |i| site("#{set}-#{i}").merge("role" => "holdout", "holdout_set" => set) } }
    names = ->(sites) { B.role_groups(sites).keys }

    assert_equal ["tuning", "holdout", "holdout set 2", "holdout set 3"],
                 names.call([site("t")] + held.call(2, 5) + held.call(3, 5))
    assert_equal %w[tuning holdout], names.call([site("t")] + held.call(2, 5) + held.call(3, 2))
  end

  # Calling run with a held-out site in the list is refused too, not only
  # the default site list.
  def test_run_refuses_held_out_sites_outside_a_release_check
    held = site("h").merge("role" => "holdout")

    error = assert_raises(ArgumentError) { B.run(sites: [held], features: { "h" => [] }) }
    assert_match(/release check/, error.message)
  end

  def test_every_held_out_site_has_its_set
    held = B.sites.select { |s| B.role(s) == "holdout" }
    assert(held.all? { |s| [2, 3].include?(s["holdout_set"]) })
  end

  # A held-out release-check run keeps no per-kind counts for held-out groups.
  def test_summary_only_drops_held_out_kinds
    view = { "in_caught" => 0.5, "kinds" => { "own_parking" => { "n" => 1 } } }
    group = { "views" => { "default" => view } }
    roles = { "tuning" => group, "holdout set 3" => group }
    run = { "sites" => [{ "id" => "h" }], "summary" => { "all" => {}, "views" => {}, "roles" => roles } }
    kept = B.summary_only(run)["summary"]["roles"]

    assert kept["tuning"]["views"]["default"].key?("kinds")
    refute kept["holdout set 3"]["views"]["default"].key?("kinds")
  end

  # The second labeller's sample carries no kinds and no positions in the
  # label file (which would hint at the kind); scoring maps the shuffled
  # numbers back to the sealed labels.
  def test_spot_check_sample_and_score
    sample = B.spot_check_sample(3)
    view = { "in" => %w[own_parking building], "out" => %w[public_road] }

    assert_equal sample, B.spot_check_sample(3)
    assert_equal (1..40).map(&:to_s).sort, sample.map { |p| p["id"] }.sort
    assert(sample.none? { |p| p.key?("kind") || p.key?("index") })

    sealed = B.spot_check_points(3).to_h { |p| [p["id"], p["kind"]] }
    assert_equal 1.0, B.spot_check_score(3, sealed, view)["kind_agreement"]
    unsure = B.spot_check_score(3, sealed.merge("1" => "unclear"), view)
    assert_equal [39, 1.0], [unsure["answered"], unsure["answered_agreement"]]
    assert_equal(["1"], unsure["disagreements"].map { |d| d["id"] })
    assert_raises(ArgumentError) { B.spot_check_score(3, sealed.except("1"), view) }
    assert_raises(ArgumentError) { B.spot_check_sample(9) }
  end

  def test_circle_ring_is_closed_and_the_right_size
    ring = B.circle_ring(PIN, 50)
    g = Curtilage::Geometry
    xy = g.open_ring(g.project(ring, PIN))

    assert_equal ring.first, ring.last
    assert(xy.all? { |p| (g.distance(p, [0, 0]) - 50).abs < 0.5 })
  end

  # Every role side by side; held-out sites outside a release check are
  # only counted.
  def test_role_table_shows_every_role_and_the_held_out_count
    stats = { "in_caught" => 0.7, "out_included" => 0.1 }
    roles = { "tuning" => { "sites" => 23, "labelled" => 23, "views" => { "default" => stats } },
              "validation" => { "sites" => 7, "labelled" => 7, "views" => { "default" => stats } } }
    lines = B.role_table({ "summary" => { "roles" => roles } }, holdout: [16, 0])

    assert_match(/tuning 23 labelled of 23, validation 7 labelled of 7/, lines[1])
    assert_match(%r{tuning 0.7 / 0.1   validation 0.7 / 0.1}, lines[2])
    assert_match(/holdout: 16 sites, 0 labelled; scored only by the release check/, lines[3])
  end

  # Held-out labels are frozen: every held-out label file in the repository
  # matches the hash it was sealed with.
  def test_held_out_labels_match_their_seals
    assert_empty B.unsealed, "held-out labels must be sealed once and never changed"
  end

  def test_sealing_adds_new_held_out_labels_and_refuses_changed_ones
    Dir.mktmpdir do |dir|
      labels = File.join(dir, "labels")
      FileUtils.mkdir_p(labels)
      file = File.join(dir, "seals")
      File.write(file, "# seals\n")
      sites = [site("h").merge("role" => "holdout"), site("t")]
      File.write(File.join(labels, "h.geojson"), "{}")
      File.write(File.join(labels, "t.geojson"), "{}")

      assert_equal [["h", "labelled but not sealed (rake benchmark:seal)"]],
                   B.unsealed(sites, labels_dir: labels, file: file)
      assert_equal ["h"], B.seal!(sites, labels_dir: labels, file: file)
      assert_empty B.unsealed(sites, labels_dir: labels, file: file)
      File.write(File.join(labels, "h.geojson"), "{\"changed\": 1}")
      assert_raises(ArgumentError) { B.seal!(sites, labels_dir: labels, file: file) }
    end
  end

  # Roles: tuning and validation are scored together; held-out sites only
  # for a release check, and then only them; old files' "holdout": true is a
  # held-out site. A held-out run keeps totals only.
  def test_held_out_sites_are_scored_only_for_a_release_check
    sites = [site("a"), site("v").merge("role" => "validation"), site("h").merge("role" => "holdout"),
             site("o").merge("holdout" => true)]

    assert_equal(%w[a v], B.scored_sites(sites).map { |s| s["id"] })
    ENV["CURTILAGE_BENCHMARK_HOLDOUT"] = "1"
    assert_raises(ArgumentError) { B.scored_sites(sites) }
    ENV["CURTILAGE_RELEASE_CHECK"] = "1"
    assert_equal(%w[a v h o], B.scored_sites(sites).map { |s| s["id"] }) # every role, side by side
    run = { "sites" => [{ "id" => "h" }], "summary" => { "all" => {}, "views" => {}, "categories" => { "x" => {} } } }
    assert_empty B.summary_only(run)["sites"]
    refute B.summary_only(run)["summary"].key?("categories")
  ensure
    ENV.delete("CURTILAGE_BENCHMARK_HOLDOUT")
    ENV.delete("CURTILAGE_RELEASE_CHECK")
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
