# frozen_string_literal: true

require_relative "test_helper"

# shared_checks: true marks large and shared buildings as estimates
# (made-up places).
class SharedChecksTest < Minitest::Test
  include SyntheticScene

  def big(type)
    [polygon("building", 1, -40, -15, 40, 15, type: type), road(4, "secondary", [[-200, -40], [200, -40]])]
  end

  def test_a_big_store_is_flagged_and_explained
    plain = Curtilage.generate(PIN, big("retail"))
    checked = Curtilage.generate(PIN, big("retail"), shared_checks: true)

    assert_includes checked.flags, :store_may_be_unit
    assert_match(/\AEstimate: the store may be one unit/, checked.explanation.first)
    assert_equal "estimate", checked.steps.first[:step]
    assert_operator checked.confidence, :<, plain.confidence
    assert_equal plain.ring, checked.ring
  end

  # A big hotel normally has one occupant: no unit flag with the checks on
  # (the default still flags it by size).
  def test_single_occupant_types_are_not_units
    assert_includes Curtilage.generate(PIN, big("hotel")).flags, :store_may_be_unit
    refute_includes Curtilage.generate(PIN, big("hotel"), shared_checks: true).flags, :store_may_be_unit
  end

  def test_buildings_joined_to_others_may_be_units
    row = scene + [polygon("building", 7, 10.5, -7.5, 25, 7.5)]

    refute_includes Curtilage.generate(PIN, row).flags, :store_may_be_unit
    assert_includes Curtilage.generate(PIN, row, shared_checks: true).flags, :store_may_be_unit
  end

  # The scene's lot (west) also touches two other buildings: claimed whole,
  # flagged as maybe shared only with the checks on.
  def test_a_lot_touching_two_other_buildings_may_be_shared
    two = scene + [polygon("building", 8, -40, 22, -25, 35), polygon("building", 9, -60, -15, -47, 15)]
    plain = Curtilage.generate(PIN, two)
    checked = Curtilage.generate(PIN, two, shared_checks: true)

    refute_includes plain.flags, :shared_lot
    assert_includes checked.flags, :shared_lot
    assert_equal plain.ring, checked.ring
  end

  def test_shared_checks_must_be_true_or_false
    assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, shared_checks: "yes") }
  end
end
