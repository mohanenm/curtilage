# frozen_string_literal: true

require_relative "test_helper"

class GeneratorTest < Minitest::Test
  include SyntheticScene

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

  # The house east (x 50-70) faces the road to the south, so the site is
  # beside it: the lot runs to the usual 3 m strip (x = 47), flagged.
  def test_lot_beside_a_house_runs_to_the_strip
    house = polygon("building", 2, 50, -10, 70, 10, type: "house")
    with_house = scene.each_with_index.map { |f, i| i == 1 ? house : f }
    result = Curtilage.generate(PIN, with_house, method: :grow_trim, grow_m: 60)

    assert_in_delta 47, xy(result).map(&:first).max, 0.5
    assert_includes result.flags, :near_houses
  end

  # The house north (y 50-70) faces a street further north, so the site is
  # behind it, across its back yard: split halfway (y = 28.75), flagged.
  def test_lot_behind_a_house_stops_halfway
    behind = [scene.first, polygon("building", 2, -10, 50, 10, 70, type: "house"),
              road(4, "secondary", [[-200, -40], [200, -40]]), road(5, "residential", [[-200, 90], [200, 90]])]
    result = Curtilage.generate(PIN, behind, method: :grow_trim, grow_m: 60)

    assert_in_delta 28.75, xy(result).map(&:last).max, 0.5
    assert(result.explanation.any? { |n| n.include?("backs onto a home") })
  end

  # A parking garage beside the building is part of the premises, not a
  # neighbour to stop short of.
  def test_parking_garage_next_door_is_claimed
    garage = scene.first(1) + [polygon("building", 8, 12, -10, 40, 10, type: "parking"),
                               road(4, "secondary", [[-200, -40], [200, -40]])]
    result = Curtilage.generate(PIN, garage, method: :grow_trim, grow_m: 10)

    assert_in_delta 40, xy(result).map(&:first).max, 0.5
    assert(result.explanation.any? { |n| n.include?("parking structure 8") })
  end

  # Untyped small buildings in a row read as a residential street.
  def test_untyped_small_buildings_in_a_row_count_as_homes
    street = scene.first(1) + [polygon("building", 21, 20, -8, 30, 2), polygon("building", 22, 20, 6, 30, 16),
                               polygon("building", 23, 20, -22, 30, -12)]
    result = Curtilage.generate(PIN, street, method: :grow_trim, grow_m: 40)

    assert_includes result.flags, :near_houses
    assert_in_delta 15, xy(result).map(&:first).max, 0.5
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

  # The road (y = -11) is closer to the building (edge y = -7.5) than half
  # its width: the premises still keep 3 m in front of the building.
  # The pin stands on the pavement 6 m from the road centreline (y = -8),
  # closer than half the road's width: the trim stops short of the pin too.
  def test_road_trim_keeps_the_pin_inside
    pavement = [polygon("building", 1, -10, 0, 10, 15), road(4, "secondary", [[-200, -8], [200, -8]])]
    result = Curtilage.generate(PIN, pavement, method: :grow_trim)

    assert_predicate result, :ok?
    assert Curtilage::Geometry.contains?(xy(result), [0.0, 0.0])
  end

  def test_kerb_offset_keeps_room_in_front_of_the_building
    tight = scene.first(3) + [road(4, "secondary", [[-200, -11], [200, -11]])]
    ys = xy(Curtilage.generate(PIN, tight, method: :grow_trim)).map(&:last)

    assert_in_delta(-10.5, ys.min, 0.5)
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

  # A lot touching one other building is still the site's: claimed whole.
  def test_lot_touching_one_neighbour_is_claimed_whole
    shared = scene + [polygon("building", 6, -70, -10, -50, 10)]
    result = Curtilage.generate(PIN, shared, method: :grow_trim, grow_m: 10)

    assert_in_delta(-45, xy(result).map(&:first).min, 0.5)
    assert(result.explanation.any? { |n| n.include?("also touches building 6") })
  end

  # A lot touching three other buildings is a shopping-centre lot: the site
  # gets the part nearer to it than to the others (halfway to the building
  # at x -60..-50 is x = -30).
  def test_shared_lot_is_split_by_nearest_building
    centre = scene + [polygon("building", 11, -40, 22, -30, 32), polygon("building", 12, -40, -32, -30, -22),
                      polygon("building", 13, -60, -5, -50, 5)]
    result = Curtilage.generate(PIN, centre, method: :grow_trim, grow_m: 10)

    assert(result.explanation.any? { |n| n.include?("is shared with 3 other buildings") })
    assert_in_delta(-30, xy(result).map(&:first).min, 0.5)
  end

  def test_centre_scope_maps_the_whole_shopping_centre
    centre = scene + [polygon("building", 11, -40, 22, -30, 32), polygon("building", 12, -40, -32, -30, -22),
                      polygon("building", 13, -60, -5, -50, 5)]
    result = Curtilage.generate(PIN, centre, preset: :centre)

    assert_includes result.flags, :shopping_centre
    xs = xy(result).map(&:first)
    assert_in_delta(-60, xs.min, 0.5)
    refute_includes Curtilage.generate(PIN, scene, preset: :centre).flags, :shopping_centre
  end

  def test_store_ring_is_the_building_outline
    result = Curtilage.generate(PIN, scene)
    store = Curtilage::Geometry.open_ring(Curtilage::Geometry.project(result.store_ring, PIN))

    assert_equal result.store_ring.first, result.store_ring.last
    assert_in_delta 300, Curtilage::Geometry.area(store), 1
    collection = result.to_geojson(include_store: true)

    assert_equal(%w[premises store], collection[:features].map { |f| f[:properties][:role] })
    refute_includes result.flags, :store_may_be_unit
  end

  def test_store_zone_can_be_turned_off
    result = Curtilage.generate(PIN, scene, store_zone: false)

    assert_predicate result, :ok?
    assert_nil result.store_ring
  end

  # A jagged 60-corner footprint comes back with at most 20 corners and
  # still doesn't cross itself.
  def test_store_ring_is_simplified
    jagged = (0...60).map do |i|
      angle = i * Math::PI / 30
      r = i.even? ? 20 : 17
      lnglat(r * Math.cos(angle), r * Math.sin(angle))
    end
    building = { "feature" => "building", "id" => 1,
                 "geometry" => { "type" => "Polygon", "coordinates" => [jagged + [jagged.first]] } }
    result = Curtilage.generate(PIN, [building, road(4, "secondary", [[-200, -40], [200, -40]])])
    store = Curtilage::Geometry.open_ring(Curtilage::Geometry.project(result.store_ring, PIN))

    assert_operator store.size, :<=, 20
    refute Curtilage::Geometry.self_intersects?(store)
  end

  # The store zone always sits inside the premises, whatever the method,
  # including an L-shaped building and premises simplified to few corners.
  def test_store_is_always_inside_the_premises
    l_shape = [[-10, -10], [20, -10], [20, 0], [0, 0], [0, 15], [-10, 15], [-10, -10]].map { |x, y| lnglat(x, y) }
    building = { "feature" => "building", "id" => 1, "geometry" => { "type" => "Polygon", "coordinates" => [l_shape] } }
    features = [building, road(4, "secondary", [[-200, -40], [200, -40]]),
                road(5, "primary", [[-60, -200], [-60, 200]])]
    [{}, { preset: :tight }, { max_vertices: 4 }].each do |options|
      result = Curtilage.generate(PIN, features, **options)
      premises = xy(result)
      store = Curtilage::Geometry.open_ring(Curtilage::Geometry.project(result.store_ring, PIN))

      assert(store.all? { |p| Curtilage::Geometry.contains?(premises, p) }, options.inspect)
    end
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

  # A driveway from the lot to the street (x = -30, from the lot south to the
  # road at y = -40) is taken in, up to the kerb (y = -32) within its 2 m
  # sampling.
  def test_driveway_to_the_street_is_taken_in
    drive = scene + [road(9, "service", [[-30, -15], [-30, -40]])]
    result = Curtilage.generate(PIN, drive, method: :grow_trim, grow_m: 10)

    assert(result.explanation.any? { |n| n.include?("driveway 9") })
    assert_in_delta(-31, xy(result).map(&:last).min, 1.1)
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
    result = Curtilage.generate(PIN, scene, grow_m: 2_000, parking_reach_m: -1)

    assert_equal :building, result.method_name
    assert_includes result.flags, :fallback
    assert_match(/grow_trim failed/, result.explanation.first)
  end

  def test_large_buildings_are_flagged_and_attached_ones_explained
    big_and_attached = [polygon("building", 1, -50, -30, 50, 30), polygon("building", 2, 50, -30, 70, 30)]
    result = Curtilage.generate(PIN, big_and_attached)

    assert_includes result.flags, :large_building
    assert_includes result.flags, :store_may_be_unit
    assert(result.explanation.any? { |n| n.include?("can't be split off") })
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
