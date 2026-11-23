# frozen_string_literal: true

require_relative "test_helper"

# entrances: :all (follow driveways to every entrance), on made-up places.
class EntrancesTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  # The usual scene's building and lot, a driveway from the lot running 140 m
  # south past a neighbour to a street, and no other public road nearby.
  def far_entrance_scene
    [
      polygon("building", 1, -10, -7.5, 10, 7.5),
      polygon("parking", 3, -45, -20, -11, 20),
      polygon("building", 5, -60, -90, -40, -70),
      road(9, "secondary", [[-300, -150], [300, -150]]),
      road(10, "service", [[-30, 0], [-30, -150]]),
    ]
  end

  def inside?(result, x, y) = G.contains?(xy(result), [x, y])

  def test_default_leaves_the_far_entrance_out
    result = Curtilage.generate(PIN, far_entrance_scene)

    assert result.ok?
    refute inside?(result, -30, -140)
  end

  def test_all_takes_in_a_corridor_to_the_kerb
    result = Curtilage.generate(PIN, far_entrance_scene, entrances: :all)
    ring = xy(result)

    assert result.ok?, result.validation.errors.inspect
    assert inside?(result, -30, -138) # the driveway, just short of the kerb (8 m from the centreline)
    refute inside?(result, -30, -146) # never past the kerb
    refute inside?(result, -60, -100) # a corridor, not a hull
    refute G.convex?(ring)
    refute G.self_intersects?(ring)
    assert G.contains?(ring, [0.0, 0.0])
    assert_operator ring.size, :<=, Curtilage::Validation::DEFAULTS[:max_vertices]
    assert_equal 0, G.overlap_area([[-59, -89], [-41, -89], [-41, -71], [-59, -71]], ring).round
    assert_includes result.details[:entrances].map { |e| e[:street_id] }, 9
    assert(result.steps.any? { |s| s[:step] == "take_entrance" })
  end

  def test_store_zone_and_buffers_fit_non_convex_premises
    result = Curtilage.generate(PIN, far_entrance_scene, entrances: :all, pickup_m: 25, approach_m: 30)
    ring = xy(result)
    store = G.open_ring(G.project(result.store_ring, PIN))

    assert G.ring_inside?(store, ring, 0.05)
    assert G.ring_inside?(G.open_ring(G.project(result.pickup_ring, PIN)), ring, 0.05)
    grown = G.open_ring(G.project(result.buffered(5), PIN))
    shrunk = G.open_ring(G.project(result.buffered(-2), PIN))

    assert(ring.all? { |p| G.contains?(grown, p) })
    assert(shrunk.all? { |p| G.contains?(ring, p) })
  end

  # A frontage road along the street serves the whole block: the walk
  # follows it at most ALONG_STREET_M past the lot, not to its far end.
  def test_frontage_roads_are_not_followed_along_the_street
    raw = scene.reject { |f| f["id"] == 2 } + [road(11, "service", [[-30, 0], [-30, -28], [250, -28], [250, -40]])]
    result = Curtilage.generate(PIN, raw, entrances: :all)

    assert result.ok?
    assert_operator xy(result).map(&:first).max, :<, 63 + Curtilage::Generator::ALONG_STREET_M + 5
  end

  def test_no_driveways_leaves_the_premises_as_they_were
    near = Curtilage.generate(PIN, scene)
    all = Curtilage.generate(PIN, scene, entrances: :all)

    assert_equal near.ring, all.ring
  end

  def test_unknown_value_is_refused
    assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, entrances: :some) }
  end
end
