# frozen_string_literal: true

require_relative "test_helper"

class PinTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  # Generates for a pin x, y metres from the scene's centre, with the
  # scene's features.
  def at(x, y, **)
    Curtilage.generate(lnglat(x, y), scene, **)
  end

  def offset(lnglat_point) = G.project([lnglat_point], PIN).first

  def test_pin_quality
    assert_equal({ quality: "on_building", building_m: 0 }, at(0, 0).pin_quality)
    assert_equal({ quality: "on_road", building_m: 32.5 }, at(0, -40).pin_quality)
    assert_equal({ quality: "near_building", building_m: 12.5 }, at(0, -20).pin_quality)
    assert_equal "far", at(0, 100).pin_quality[:quality]
    row = Curtilage::Formats.parse_csv(Curtilage::Formats.write([at(0, -20)], :csv))[1]

    assert_equal "near_building", row[Curtilage::Formats::CSV_COLUMNS.index("pin_quality")]
  end

  def test_snapping_moves_the_pin_just_inside_the_nearest_building
    r = at(0, -20, snap_m: 30)
    x, y = offset(r.pin)

    assert_includes r.flags, :pin_moved
    assert_in_delta 0, x, 0.01
    assert_in_delta(-6.5, y, 0.01) # the building's south wall is at -7.5
    assert_equal lnglat(0, -20), r.pin_quality[:moved_from]
    assert_equal "near_building", r.pin_quality[:quality]
    step = r.steps.find { |s| s[:step] == "snap_pin" }

    assert_equal ["snap_m", [1], 13.5], step.values_at(:rule, :features, :distance_m)
    refute r.confidence_factors.find { |f| f[:name] == :building_under_pin }[:met]
  end

  def test_a_pin_on_the_road_no_longer_pulls_the_premises_into_it
    south = ->(r) { G.open_ring(G.project(r.ring, PIN)).map(&:last).min }

    # The road's centreline is at -40 and it's 8 m to the kerb (a secondary road): the pin at -33 is on it.
    assert_equal "on_road", at(0, -33).pin_quality[:quality]
    assert_operator south.call(at(0, -33)), :<, -35, "the premises have to hold the pin, 5 m clear"
    assert_operator south.call(at(0, -33, snap_m: 30)), :>=, -32.5, "snapped, they stop at the kerb"
  end

  def test_no_snapping_on_a_building_or_out_of_reach
    refute_includes at(3, 2, snap_m: 30).flags, :pin_moved
    assert_equal lnglat(3, 2), at(3, 2, snap_m: 30).pin
    assert_nil at(0, 100, snap_m: 30).pin_quality[:moved_from]
  end

  def test_moved_features_shift_with_the_pin
    features = Curtilage::Features.new(PIN, scene)
    moved = features.moved_to([10.0, -5.0])

    assert_equal(features.buildings.first.xy.map { |x, y| [x - 10, y + 5] }, moved.buildings.first.xy)
    assert_equal features.roads.first.xy.map { |x, y| [x - 10, y + 5] }, moved.roads.first.xy
    x, y = offset(moved.pin)

    assert_in_delta 10, x, 0.01
    assert_in_delta(-5, y, 0.01)
  end
end
