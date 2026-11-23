# frozen_string_literal: true

require_relative "test_helper"

# Synthetic coordinates only: a made-up pin, with rings built in metres.
class ValidationTest < Minitest::Test
  PIN = [-80.0, 35.0].freeze

  def ring(*offsets, close: true)
    scale_x = Math.cos(PIN[1] * Math::PI / 180) * Curtilage::Geometry::METRES_PER_DEGREE_LNG_AT_EQUATOR
    points = offsets.map { |x, y| [PIN[0] + (x / scale_x), PIN[1] + (y / Curtilage::Geometry::METRES_PER_DEGREE_LAT)] }
    close ? points + [points.first] : points
  end

  def rectangle(width, height, dx: 0, dy: 0)
    ring([dx - (width / 2.0), dy - (height / 2.0)], [dx + (width / 2.0), dy - (height / 2.0)],
         [dx + (width / 2.0), dy + (height / 2.0)], [dx - (width / 2.0), dy + (height / 2.0)])
  end

  def check(premises, **)
    Curtilage::Validation.check(PIN, premises, **)
  end

  def test_typical_store_premises_pass_cleanly
    result = check(rectangle(80, 60))

    assert_predicate result, :ok?
    assert_empty result.warnings
    assert_in_delta 4800, result.metrics[:area_m2], 5
    assert_in_delta 1.0, result.metrics[:rectangularity], 0.01
  end

  def test_missing_invalid_and_degenerate
    assert_equal ["missing"], check(nil).errors
    assert_equal ["invalid_coordinates"], check([[-80.0, 135.0], [-80.0, 35.0], [-79.9, 35.0]]).errors
    assert_includes check(rectangle(80, 60).first(2)).errors, "too_few_points"
    assert_includes check(rectangle(80, 60)[0...-1]).errors, "unclosed"
  end

  def test_swapped_and_self_intersecting
    assert_includes check(rectangle(80, 60).map(&:reverse)).errors, "swapped"
    assert_includes check(ring([-40, -25], [40, 25], [40, -25], [-40, 25])).errors, "self_intersecting"
  end

  def test_pin_and_distance_errors
    assert_includes check(rectangle(40, 40, dx: 60)).errors, "pin_outside"
    assert_includes check(rectangle(2400, 100, dx: 0)).errors, "too_far_from_pin"
  end

  def test_size_and_centre_warnings
    assert_includes check(rectangle(20, 20)).warnings, "small"
    assert_includes check(rectangle(300, 200)).warnings, "large"
    assert_includes check(rectangle(600, 100, dx: 250)).warnings, "off_centre"
    assert_includes check(rectangle(500, 300)).errors, "too_large"
  end

  def test_thresholds_can_be_overridden
    assert_empty check(rectangle(20, 20), min_area_m2: 100).warnings
  end

  def test_pins_are_two_finite_decimal_numbers_in_range
    assert_equal [-80.0, 35.0], Curtilage::Validation.pin([-80, 35])
    assert_equal [-80.25, 35.0], Curtilage::Validation.pin([" -80.25 ", "35"])
    assert_equal [-0.0, 1.0e-3], Curtilage::Validation.pin(["-0.0", "1e-3"])
    [%w[0x1A 35], %w[1_0 35], %w[1e400 35], %w[NaN 35], %w[Infinity 35], [Float::NAN, 35],
     [Float::INFINITY, 35], [nil, 35], ["", "35"], [-80.0], nil, "-80,35", [-181, 35], [-80, 91], %W[\uFF10 35]]
      .each { |pin| assert_raises(ArgumentError, pin.inspect) { Curtilage::Validation.pin(pin) } }
  end

  def test_every_entry_point_checks_the_pin
    assert_raises(ArgumentError) { Curtilage.generate([Float::NAN, 35.0], []) }
    assert_raises(ArgumentError) { Curtilage::Lookup.checked(%w[0x1A 35]) }
    assert_raises(ArgumentError) { Curtilage::Formats.parse_pins("lng,lat\n0x1A,35\n", :csv) }
    assert_raises(ArgumentError) { Curtilage::Formats.parse_pins("lng,lat\n1e400,35\n", :csv) }
    assert_raises(ArgumentError) { Curtilage::Formats.parse_pins("lng,lat\n-80,95\n", :csv) }
    point = '{"type":"Feature","geometry":{"type":"Point","coordinates":["1_0",35]}}'
    assert_raises(ArgumentError) { Curtilage::Formats.parse_pins(point, :geojson) }
    assert_raises(ArgumentError) { Curtilage::Formats.pin_from_text("-80,35,1") }
    assert_equal [-80.0, 35.0], Curtilage::Formats.pin_from_text(" -80 , 35 ")
  end
end
