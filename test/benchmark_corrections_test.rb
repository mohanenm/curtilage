# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"
require "tmpdir"

# The corrections log and the review sample (benchmark/corrections.rb,
# benchmark/review_sample.rb), on made-up places.
class BenchmarkCorrectionsTest < Minitest::Test
  include SyntheticScene

  B = CurtilageBenchmark
  VIEW = { "name" => "test", "in" => %w[own_parking entrance], "out" => %w[public_road] }.freeze

  def square = [[-50, -50], [50, -50], [50, 50], [-50, 50], [-50, -50]].map { |x, y| lnglat(x, y) }
  def xy = G.counter_clockwise(G.open_ring(G.project(square, PIN)))

  def point(kind, x, y)
    { "type" => "Feature", "properties" => { "kind" => kind }, "geometry" => { "coordinates" => lnglat(x, y) } }
  end

  G = Curtilage::Geometry

  def test_label_diffs_find_changed_added_and_deleted_points
    old = { "features" => [point("own_parking", 0, 0), point("entrance", 60, 0), point("public_road", 70, 0)] }
    new = { "features" => [point("own_parking", 0, 0), point("public_road", 60, 0), point("own_parking", 10, 10)] }

    diffs = B.label_diffs(old, new).to_h { |p, a, b| [p, [a, b]] }
    assert_equal %w[entrance public_road], diffs[lnglat(60, 0)]
    assert_equal ["public_road", nil], diffs[lnglat(70, 0)]
    assert_equal [nil, "own_parking"], diffs[lnglat(10, 10)]
    refute diffs.key?(lnglat(0, 0))
  end

  # A wrong point made right (or no longer scored) raises the score; a right
  # one made wrong (or no longer scored) lowers it.
  def test_correction_effects
    outside = lnglat(60, 0)
    inside = lnglat(0, 0)

    assert_equal :raised, B.correction_effect(VIEW, xy, PIN, [outside, "entrance", "public_road"])
    assert_equal :raised, B.correction_effect(VIEW, xy, PIN, [outside, "entrance", nil])
    assert_equal :lowered, B.correction_effect(VIEW, xy, PIN, [inside, "own_parking", "public_road"])
    assert_equal :lowered, B.correction_effect(VIEW, xy, PIN, [inside, "own_parking", "sidewalk"])
    assert_equal :none, B.correction_effect(VIEW, xy, PIN, [inside, "own_parking", "entrance"])
  end

  def test_corrections_round_trip_through_the_log
    Dir.mktmpdir do |dir|
      file = File.join(dir, "c.csv")
      row = ["2026-11-24", "abc1234", "site-a", "tuning", "-75.1 39.2", "own_parking", "shared_parking_near",
             'a reason, with "quotes"', "imagery", "yes", "raised", "none"]
      B.write_corrections([row], file)
      B.append_corrections([row], file)

      rows = B.read_corrections(file)
      assert_equal 2, rows.size
      assert_equal 'a reason, with "quotes"', rows[0]["reason"]
      assert_equal "-75.1 39.2", rows[1]["point"]
    end
  end

  # Every correction logged after the backfill says its review sample was
  # looked at.
  def test_new_corrections_record_the_review_sample
    late = B.read_corrections.reject { |r| r["sample_reviewed"].start_with?("n/a") }
    assert(late.all? { |r| r["sample_reviewed"] == "yes" }, "review the four-outcome sample before correcting a label")
  end

  def test_review_sample_covers_all_four_outcomes_and_refuses_held_out_sites
    site = { "id" => "made-up", "pin" => PIN }
    labels = [["own_parking", 0, 0], ["entrance", 60, 0], ["public_road", 10, 0], ["public_road", 70, 0],
              ["sidewalk", 5, 5]].map { |k, x, y| { "kind" => k, "point" => lnglat(x, y) } }

    sample = B.review_sample(site, square, labels, VIEW)
    assert_equal B::OUTCOMES, sample.keys
    assert(sample.values.all? { |l| l.size == 1 })
    assert_equal "entrance", sample["in_missed"][0]["kind"]
    assert_raises(ArgumentError) { B.review_sample(site.merge("role" => "holdout"), square, labels, VIEW) }
  end
end
