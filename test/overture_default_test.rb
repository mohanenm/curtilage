# frozen_string_literal: true

require_relative "test_helper"

# Overture reads (source: :overture, and :auto's scattered pins) use ML
# footprints only where OSM has no building near the pin, unless buildings:
# is given. Overture is stubbed: made-up features, no network.
class OvertureDefaultTest < Minitest::Test
  include SyntheticScene

  def only_ml
    [polygon("ml_building", -1, -10, -7.5, 10, 7.5), road(4, "secondary", [[-200, -40], [200, -40]])]
  end

  def read(features, **)
    with_stub(Curtilage::Overture, :features_many, ->(pins, **) { pins.map { features } }) do
      Curtilage.generate_many([PIN], source: :overture, data: { release: "2026-11-18.0" }, **).first
    end
  end

  def test_missing_building_is_filled_from_ml_footprints
    result = read(only_ml)

    assert_predicate result, :ok?
    assert_includes result.flags, :ml_footprint
    assert_equal :osm_or_ml, result.provenance.dig(:options, :buildings)
  end

  def test_an_explicit_choice_wins
    refute_predicate read(only_ml, buildings: :osm), :ok?
  end

  def test_sites_with_an_osm_building_are_unchanged
    with_ml = scene + [polygon("ml_building", -2, -30, -6, -24, 6)]

    assert_equal Curtilage.generate(PIN, with_ml).ring, read(with_ml).ring
  end
end
