# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"

# The diagnosis (benchmark/diagnose.rb) on made-up diagnoses.
class BenchmarkDiagnoseTest < Minitest::Test
  B = CurtilageBenchmark

  def point(cause, want, view = "default") = { "view" => view, "kind" => "k", "want" => want, "cause" => cause }

  # Two sites: a has 4 in / 2 out points, b has 2 in / 2 out.
  def diagnoses
    [{ "id" => "a", "role" => "tuning", "pin_bucket" => "on_right_building", "site_cause" => nil,
       "totals" => { "default" => [4, 2] },
       "points" => [point("reach", true), point("reach", true), point("road", false)] },
     { "id" => "b", "role" => "tuning", "pin_bucket" => "wrong_building", "site_cause" => "pin on the wrong building",
       "totals" => { "default" => [2, 2] }, "points" => [point("reach", true)] }]
  end

  # Averaged per site, as the benchmark averages: in caught (0.5 + 0.5) / 2,
  # out taken in (0.5 + 0) / 2.
  def test_scores_average_per_site_and_split_by_pin_bucket
    assert_equal [2, 0.5, 0.25], B.group_score(diagnoses, "default")
    split = B.split_scores(diagnoses)["default"]
    assert_equal [1, 0.5, 0.5], split["on_right_building"]
    assert_equal [1, 0.5, 0.0], split["wrong_building"]
  end

  def test_causes_are_ranked_by_what_fixing_them_would_gain
    rows = B.cause_table(diagnoses)["default"]
    assert_equal [["reach", 3, 0, 0.5, 0.0], ["road", 0, 1, 0.0, 0.25]], rows
  end

  def test_point_causes
    edge = B.point_cause({}, "default", { "kind" => "own_parking" }, true, edge: true)
    assert_match(/on the edge/, edge["cause"])
    assert_equal "road trim (road width)", B.included_cause({ "kind" => "public_road" })
    assert_equal "other", B.included_cause({ "kind" => "something_new" })
  end

  def test_label_totals_count_only_what_the_view_scores
    view = { "in" => %w[own_parking], "out" => %w[public_road] }
    labels = %w[own_parking own_parking public_road sidewalk].map { |k| { "kind" => k } }
    assert_equal({ "v" => [2, 1] }, B.label_totals(labels, { "v" => view }))
  end

  def test_rank_correlation
    assert_in_delta(-1.0, B.spearman([0.9, 0.5, 0.1], [0.0, 0.2, 0.6]))
    assert_equal [0.5, 0.5, 2.0], B.ranks([3, 3, 7])
    assert_nil B.spearman([1, 2], [2, 1])
  end

  def test_flag_report_keeps_held_out_sites_to_totals
    rows = %w[tuning holdout].flat_map do |role|
      [0.1, 0.4, 0.2].each_with_index.map do |e, i|
        { "id" => "#{role}-#{i}", "role" => role, "error" => e, "confidence" => 1 - e, "flags" => [] }
      end
    end
    text = B.flag_report(rows).join("\n")

    assert_includes text, "worst sites: tuning-1"
    refute_includes text, "holdout-"
  end

  def test_held_out_sites_are_never_diagnosed
    assert_empty B.diagnose([{ "id" => "x", "role" => "holdout", "pin" => [0, 0] }], {}, {}, {})
  end
end
