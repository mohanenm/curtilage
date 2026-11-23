# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"
require "tmpdir"

# Scoring against labelled points (benchmark/labels.rb), on made-up places.
class BenchmarkLabelsTest < Minitest::Test
  include SyntheticScene

  B = CurtilageBenchmark
  VIEW = { "name" => "test", "options" => {}, "in" => %w[own_parking entrance],
           "out" => %w[public_road open_land] }.freeze

  # A 100 m square around the pin, as [lng, lat], closed.
  def square
    [[-50, -50], [50, -50], [50, 50], [-50, 50], [-50, -50]].map { |x, y| lnglat(x, y) }
  end

  def point(kind, x, y) = { "kind" => kind, "point" => lnglat(x, y), "source" => "hand" }

  def labels
    [point("own_parking", 0, 0), point("own_parking", 40, 40), point("entrance", 60, 0), # missed, hard
     point("public_road", 70, 0), point("public_road", 49, 10), # taken in, near the edge
     point("open_land", -80, -80), point("sidewalk", 0, 55)] # sidewalk: not in this view
  end

  def test_scores_in_and_out_points_per_kind
    score = B.score_labels(VIEW, square, labels, PIN)

    assert_equal [3, 2, 3, 1], score.values_at("in", "caught", "out", "included")
    assert_equal 2, B.errors(score)
    assert_equal 1, score["wrong_near_edge"] # the road point 1 m inside the edge
    assert_equal ["missed entrance", "took in public_road"], score["hard"]
    assert_equal({ "n" => 2, "right" => 1 }, score["kinds"]["public_road"])
    refute score["kinds"].key?("sidewalk")
  end

  def test_random_points_are_scored_apart
    random = [point("public_road", 10, 0).merge("source" => "random"),
              point("open_land", 80, 80).merge("source" => "random")]
    score = B.score_labels(VIEW, square, labels + random, PIN)

    assert_equal 3, score["out"] # hand-placed only
    assert_equal [0, 2, 1], score["random"].values_at("in", "out", "included")
    assert_equal 3, B.errors(score) # both count
    assert_equal 1, B.label_stats([score])["random"]["errors"]
  end

  def test_no_premises_catches_nothing
    score = B.score_labels(VIEW, nil, labels, PIN)

    assert_equal [0, 0], score.values_at("caught", "included")
  end

  def test_gallery_says_what_failed_and_loads_nothing
    site = { "id" => "made-up", "category" => "standalone", "notes" => "A made-up site.", "pin" => PIN }
    html = Dir.mktmpdir { |dir| B.gallery([site], { "made-up" => scene }, dir, VIEW, {}) }
    note = B.gallery_note(site, Curtilage.generate(PIN, scene), labels, VIEW)

    assert_includes html, "standalone: A made-up site. Not labelled yet."
    refute_match(%r{https?://|(src|href)=}, html)
    assert_match(/caught \d of 3 .* took in \d of 3 .* Failed: missed entrance/, note)
  end

  def test_stats_average_per_site_and_changes_are_paired
    good = B.score_labels(VIEW, square, labels, PIN)
    none = B.score_labels(VIEW, nil, labels, PIN)
    stats = B.label_stats([good, none])

    assert_in_delta (2.0 / 3) / 2, stats["in_caught"], 0.001
    assert_in_delta (1.0 / 3) / 2, stats["out_included"], 0.001
    assert_equal 2, stats["hard_failures"]

    old = { "sites" => [{ "id" => "a", "views" => { "test" => none } }] }
    new = { "sites" => [{ "id" => "a", "views" => { "test" => good } }] }

    assert_includes B.label_changes(old, new), "test: 1 better, 0 worse, 0 same"
    refute B.numbers_only(new.merge("sites" => new["sites"]))["sites"][0]["views"]["test"].key?("wrong")
  end

  def test_views_and_labels_are_checked
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "bad.json"), JSON.generate("name" => "bad", "in" => ["moat"]))
      assert_raises(ArgumentError) { B.views(dir) }

      File.write(File.join(dir, "bad.json"), JSON.generate("name" => "bad", "in" => ["railway"], "out" => ["railway"]))
      assert_raises(ArgumentError) { B.views(dir) }

      moat = { "geometry" => { "type" => "Point", "coordinates" => [1, 2] }, "properties" => { "kind" => "moat" } }
      File.write(File.join(dir, "x.geojson"), JSON.generate("features" => [moat]))
      assert_raises(ArgumentError) { B.labels("x", dir) }
      assert_nil B.labels("missing", dir)
    end
  end

  def test_the_shipped_views_load_and_cover_only_known_kinds
    views = B.views(File.join(B::DIR, "views"))

    assert_equal %w[arrival centre core default], views.keys.sort
    assert_equal({ "scope" => "centre" }, views["centre"]["options"])
  end

  def test_private_folder_never_fetches
    Dir.mktmpdir do |dir|
      paths = B.paths(dir)

      assert paths[:private]
      assert_equal File.join(File.expand_path(dir), "cache"), paths[:cache]
      assert_raises(ArgumentError) { B.refuse_fetch([PIN]) }
    end
  end
end

# The labelling page: every kind has a key, site text can't end the script,
# and only public-domain imagery is offered.
class LabelPageTest < Minitest::Test
  B = CurtilageBenchmark

  def test_page_lists_kinds_and_escapes_site_text
    sites = [{ "id" => "a", "category" => "standalone", "notes" => "</script><b>", "pin" => [-80.0, 35.0] }]
    html = Dir.mktmpdir { |dir| B.label_page(sites, dir) }

    assert_equal B::KINDS.size, B::KEYS.size
    assert_equal B::KINDS.sort, B::KIND_NOTES.keys.sort
    B::KINDS.each { |k| assert_includes html, "\"#{k}\"" }
    refute_includes html, "</script><b>"
    refute_includes html, "Esri"
  end
end
