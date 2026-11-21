# frozen_string_literal: true

require_relative "test_helper"

# Synthetic scene: a 20 x 15 m building at a made-up pin, a public road 40 m
# south, a neighbour 50 m east and a parking lot west of the building.
class GeneratorTest < Minitest::Test
  PIN = [-80.0, 35.0].freeze

  def lnglat(x, y)
    sx = Curtilage::Geometry.metres_per_degree_lng(PIN[1])
    [PIN[0] + (x / sx), PIN[1] + (y / Curtilage::Geometry::METRES_PER_DEGREE_LAT)]
  end

  def polygon(kind, id, x0, y0, x1, y1)
    ring = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]].map { |x, y| lnglat(x, y) }
    { "feature" => kind, "id" => id, "geometry" => { "type" => "Polygon", "coordinates" => [ring] } }
  end

  def road(id, highway, points)
    { "feature" => "road", "id" => id, "highway" => highway,
      "geometry" => { "type" => "LineString", "coordinates" => points.map { |x, y| lnglat(x, y) } } }
  end

  def scene
    [
      polygon("building", 1, -10, -7.5, 10, 7.5),
      polygon("building", 2, 50, -10, 70, 10),
      polygon("parking", 3, -45, -20, -11, 20),
      road(4, "secondary", [[-200, -40], [200, -40]]),
    ]
  end

  def xy(result)
    Curtilage::Geometry.open_ring(Curtilage::Geometry.project(result.ring, PIN))
  end

  def test_every_method_gives_a_valid_ring_around_the_pin
    Curtilage::Generator::METHODS.each do |method|
      result = Curtilage.generate(PIN, scene, method: method)

      assert_predicate result, :ok?, "#{method}: #{result.validation.errors}"
      assert_equal result.ring.first, result.ring.last
      refute_empty result.explanation
    end
  end

  def test_building_method_is_the_rectangle_plus_margin
    result = Curtilage.generate(PIN, scene, method: :building, building_margin_m: 10)

    assert_in_delta 40 * 35, result.validation.metrics[:area_m2], 5
    assert_equal 1, result.building
  end

  # The secondary road's centreline is at y = -40; half its width is 8 m.
  def test_building_method_stops_at_the_kerb
    ys = xy(Curtilage.generate(PIN, scene, method: :building, building_margin_m: 40)).map(&:last)

    assert_in_delta(-32, ys.min, 0.5)
  end

  def test_grow_trim_stops_at_the_kerb_and_halfway_to_the_neighbour
    points = xy(Curtilage.generate(PIN, scene, method: :grow_trim, grow_m: 60))

    assert_in_delta(-32, points.map(&:last).min, 0.5)
    assert_in_delta 30, points.map(&:first).max, 0.5
  end

  def test_kerb_offset_never_cuts_into_the_building
    tight = scene.first(3) + [road(4, "secondary", [[-200, -11], [200, -11]])]
    ys = xy(Curtilage.generate(PIN, tight, method: :grow_trim)).map(&:last)

    assert_in_delta(-7.5, ys.min, 0.5)
  end

  # A neighbour off the building's corner is cut square to a building side,
  # not along a diagonal.
  def test_neighbour_cut_is_square_to_the_building
    corner = [polygon("building", 1, -10, -7.5, 10, 7.5), polygon("building", 2, 20, 20, 40, 40)]
    points = xy(Curtilage.generate(PIN, corner, method: :grow_trim, grow_m: 40))

    assert_equal 4, points.size
  end

  def test_propose_uses_grow_trim_when_it_validates
    result = Curtilage.generate(PIN, scene)

    assert_predicate result, :ok?
    assert_equal :grow_trim, result.method_name
    assert_empty result.flags
  end

  # Nothing bounds a 2 km grow to the north, so grow_trim fails validation
  # (too large) and the building fallback is used.
  def test_propose_falls_back_to_building_and_flags_it
    result = Curtilage.generate(PIN, scene, grow_m: 2_000)

    assert_equal :building, result.method_name
    assert_includes result.flags, :fallback
    assert_match(/grow_trim failed/, result.explanation.first)
  end

  def test_large_and_attached_buildings_are_flagged
    big_and_attached = [polygon("building", 1, -40, -25, 40, 25), polygon("building", 2, 40, -25, 60, 25)]
    result = Curtilage.generate(PIN, big_and_attached)

    assert_includes result.flags, :large_building
    assert_includes result.flags, :attached_building
  end

  def test_no_building_nearby_gives_no_ring
    result = Curtilage.generate(PIN, [polygon("building", 1, 100, 100, 120, 120)], method: :grow_trim)

    refute_predicate result, :ok?
    assert_nil result.ring
    assert_match(/no building within/, result.explanation.last)
  end

  def test_untrusted_geometry_is_dropped_not_raised
    junk = [
      { "feature" => "building", "geometry" => { "type" => "Polygon", "coordinates" => "x" } },
      { "feature" => "building", "geometry" => { "type" => "Polygon", "coordinates" => [[[1, 2], [3]]] } },
      { "feature" => "building", "geometry" => nil },
      { "feature" => "road", "geometry" => { "type" => "LineString", "coordinates" => [[999, 2], [3, 4]] } },
      polygon("building", 9, 0, 0, 0, 0),
    ]
    features = Curtilage::Features.new(PIN, scene + junk)

    assert_equal 5, features.dropped
    assert_equal 2, features.buildings.size
  end

  # A vandalised or wrong building under the pin (here 1.4 km wide) must not
  # come out as usable premises.
  def test_validation_rejects_output_from_a_huge_building
    huge = [polygon("building", 1, -700, -300, 700, 300)]
    result = Curtilage.generate(PIN, huge, method: :building)

    refute_predicate result, :ok?
    assert_includes result.validation.errors, "too_large"
  end
end
