# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"

# Bootstrap intervals over sites, on made-up runs.
class BenchmarkIntervalsTest < Minitest::Test
  B = CurtilageBenchmark

  def site(id, caught, included, role: "tuning")
    { "id" => id, "role" => role, "views" => { "default" => { "in" => 10, "caught" => caught, "out" => 10,
                                                              "included" => included } } }
  end

  def test_equal_sites_give_a_point_interval
    assert_equal [0.5, 0.5, 0.5], B.bootstrap([0.5] * 8)
    assert_nil B.bootstrap([])
  end

  def test_interval_holds_the_mean_and_widens_with_spread
    low, mid, high = B.bootstrap([0.0, 1.0] * 10).values_at(1, 0, 2)

    assert_in_delta 0.5, mid, 1e-9
    assert_operator low, :<, 0.5
    assert_operator high, :>, 0.5
  end

  # Every site gains 2 of 10 "in" points: the difference is 0.2 exactly.
  def test_paired_difference_is_per_site
    old = { "sites" => (1..6).map { |i| site(i.to_s, 5, 1) } }
    new = { "sites" => (1..6).map { |i| site(i.to_s, 7, 1) } }
    r = B.paired_intervals(old, new, %w[default])[%w[tuning default]]

    assert_equal 6, r["sites"]
    assert_equal [0.2, 0.2, 0.2], r["in"]
    assert_equal [0.0, 0.0, 0.0], r["out"]
  end
end
