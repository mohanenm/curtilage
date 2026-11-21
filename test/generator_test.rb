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

  # The neighbour's wall is at x = 50: the lot runs to 3 m short of it.
  def test_grow_trim_stops_at_the_kerb_and_short_of_the_neighbour
    points = xy(Curtilage.generate(PIN, scene, method: :grow_trim, grow_m: 60))

    assert_in_delta(-32, points.map(&:last).min, 0.5)
    assert_in_delta 47, points.map(&:first).max, 0.5
  end

  def test_neighbour_gap_nil_splits_halfway
    xs = xy(Curtilage.generate(PIN, scene, method: :grow_trim, grow_m: 60, neighbour_gap_m: nil)).map(&:first)

    assert_in_delta 30, xs.max, 0.5
  end

  # A gap narrower than two strips is still split down the middle.
  def test_narrow_gap_is_split_halfway
    close = scene.first(1) + [polygon("building", 2, 14, -10, 30, 10)]
    xs = xy(Curtilage.generate(PIN, close, method: :grow_trim)).map(&:first)

    assert_in_delta 12, xs.max, 0.5
  end

  # A railway 30 m north bounds the lot like a road: 5 m short of the track.
  def test_railway_bounds_the_premises
    with_rail = scene + [{ "feature" => "railway", "id" => 7, "highway" => "rail",
                           "geometry" => { "type" => "LineString",
                                           "coordinates" => [lnglat(-200, 30), lnglat(200, 30)] } }]
    result = Curtilage.generate(PIN, with_rail, method: :grow_trim, grow_m: 60)

    assert_in_delta 25, xy(result).map(&:last).max, 0.5
    assert(result.explanation.any? { |n| n.include?("railway 7 (rail)") })
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

  # The parking west of the building (x -45 to -11) touches it, so the
  # premises take the whole lot instead of stopping at the 30 m grow.
  def test_grow_trim_claims_adjacent_mapped_parking
    result = Curtilage.generate(PIN, scene, method: :grow_trim, grow_m: 10)

    assert_in_delta(-45, xy(result).map(&:first).min, 0.5)
    assert(result.explanation.any? { |n| n.include?("parking 3") })
  end

  def test_shared_parking_is_split_halfway_with_the_neighbour
    shared = scene + [polygon("building", 6, -70, -10, -50, 10)]
    xs = xy(Curtilage.generate(PIN, shared, method: :grow_trim, grow_m: 10)).map(&:first)

    assert_in_delta(-30, xs.min, 0.5)
  end

  # A lot touching three other buildings is a shopping-centre lot.
  def test_shared_lot_is_left_out_and_flagged
    centre = scene + [polygon("building", 11, -40, 22, -30, 32), polygon("building", 12, -40, -32, -30, -22),
                      polygon("building", 13, -60, -5, -50, 5)]
    result = Curtilage.generate(PIN, centre, method: :grow_trim, grow_m: 10)

    assert_includes result.flags, :shared_parking
    assert_operator xy(result).map(&:first).min, :>, -25
  end

  def test_tiny_building_is_flagged
    kiosk = [polygon("building", 1, -3, -3, 3, 3), road(4, "secondary", [[-200, -40], [200, -40]])]

    assert_includes Curtilage.generate(PIN, kiosk).flags, :small_building
  end

  def test_presets
    tight = Curtilage.generate(PIN, scene, preset: :tight)

    assert_equal :building, tight.method_name
    assert_in_delta 36 * 31, tight.validation.metrics[:area_m2], 5
    assert_equal :grow_trim, Curtilage.generate(PIN, scene, preset: :whole_lot).method_name
    assert_in_delta 40 * 35, Curtilage.generate(PIN, scene, preset: :tight, building_margin_m: 10)
                                      .validation.metrics[:area_m2], 5
    assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, preset: :roomy) }
  end

  def test_to_geojson
    json = Curtilage.generate(PIN, scene).to_geojson

    assert_equal "Polygon", json[:geometry][:type]
    assert json[:properties][:ok]
    assert_equal ["© OpenStreetMap contributors"], json[:properties][:attribution]
  end

  def test_audit_flags_a_polygon_over_the_road_and_the_neighbour
    sprawling = [lnglat(-20, -60), lnglat(70, -60), lnglat(70, 20), lnglat(-20, 20), lnglat(-20, -60)]
    report = Curtilage::Audit.check(PIN, sprawling, scene)

    assert_equal :review, report.verdict
    assert_includes report.reasons, "crosses_road"
    assert_includes report.reasons, "covers_neighbour"
  end

  def test_audit_passes_the_generated_polygon
    report = Curtilage::Audit.check(PIN, Curtilage.generate(PIN, scene).ring, scene)

    assert_equal :ok, report.verdict
    assert_in_delta 1.0, report.overlap, 0.01
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

  def ml(id, x0, y0, x1, y1)
    polygon("ml_building", id, x0, y0, x1, y1)
  end

  # OSM has no building at the pin; an ML footprint does.
  def test_building_flavours
    only_ml = [ml(-1, -10, -7.5, 10, 7.5), road(4, "secondary", [[-200, -40], [200, -40]])]

    refute_predicate Curtilage.generate(PIN, only_ml), :ok?
    filled = Curtilage.generate(PIN, only_ml, buildings: :osm_filled)

    assert_predicate filled, :ok?
    assert_includes filled.flags, :ml_footprint
    assert_predicate Curtilage.generate(PIN, only_ml, buildings: :ml), :ok?
  end

  # Where OSM and ML overlap, OSM wins and the result isn't flagged.
  def test_osm_filled_prefers_osm
    both = scene + [ml(-1, -11, -8, 11, 8)]
    result = Curtilage.generate(PIN, both, buildings: :osm_filled)

    assert_equal 1, result.building
    refute_includes result.flags, :ml_footprint
  end

  def test_unknown_building_flavour
    assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, buildings: :google) }
  end

  # A state built from two extracts lists seam features twice.
  def test_duplicate_features_are_ignored
    features = Curtilage::Features.new(PIN, scene + scene)

    assert_equal 2, features.buildings.size
    assert_equal 1, features.roads.size
    assert_equal 2, Curtilage::Features.new(PIN, [ml(-1, 0, 0, 5, 5), ml(-1, 20, 20, 25, 25)]).ml_buildings.size
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
