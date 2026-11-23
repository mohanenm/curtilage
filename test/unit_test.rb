# frozen_string_literal: true

require_relative "test_helper"

# unit_m: an estimated unit of a large, shared building (made-up strip mall).
class UnitTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  # A 120 m x 20 m strip of shops along a street to the south; the pin is
  # near the west end.
  def strip_mall
    [polygon("building", 1, -20, -10, 100, 10), road(4, "secondary", [[-300, -40], [300, -40]])]
  end

  def store(result) = G.open_ring(G.project(result.store_ring, PIN))

  def test_store_zone_is_a_slice_of_the_frontage_round_the_pin
    result = Curtilage.generate(PIN, strip_mall, unit_m: 15)
    xs = store(result).map(&:first)

    assert result.ok?
    assert_includes result.flags, :unit_estimated
    refute_includes result.flags, :store_may_be_unit
    assert_in_delta(-7.5, xs.min, 0.2)
    assert_in_delta 7.5, xs.max, 0.2
    assert G.ring_inside?(store(result), xy(result), 0.01)
  end

  def test_slice_stays_within_the_building_and_small_buildings_are_left_whole
    near_end = Curtilage.generate(PIN, [polygon("building", 1, -5, -10, 115, 10)] + strip_mall.drop(1), unit_m: 15)

    assert_in_delta(-5, store(near_end).map(&:first).min, 0.2)
    small = Curtilage.generate(PIN, scene, unit_m: 15)

    refute_includes small.flags, :unit_estimated
    assert_equal Curtilage.generate(PIN, scene).store_ring, small.store_ring
  end
end
