# frozen_string_literal: true

require_relative "test_helper"

# Geofence-ready shapes: circles and vertex limits (made-up sites).
class GeofenceTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  def result(**) = Curtilage.generate(PIN, scene, **)

  def local(point) = G.project([point], PIN).first

  def test_enclosing_circle_holds_every_corner
    r = result
    circle = r.enclosing_circle
    centre = local(circle[:centre])

    assert(xy(r).all? { |p| G.distance(centre, p) <= circle[:radius_m] })
    assert_operator circle[:radius_m], :<, G.distance([0, 0], xy(r).max_by { |p| G.distance([0, 0], p) }) * 2
  end

  def test_fit_circle_has_the_premises_area
    r = result
    circle = r.fit_circle

    assert_in_delta G.area(xy(r)), Math::PI * (circle[:radius_m]**2), G.area(xy(r)) * 0.01
    assert G.contains?(xy(r), local(circle[:centre]))
  end

  def test_simplified_keeps_the_pin_and_store_inside
    r = result(entrances: :all) # any shape works; here usually convex
    ring = G.open_ring(G.project(r.simplified(4), PIN))
    store = G.open_ring(G.project(r.store_ring, PIN))

    assert_operator ring.size, :<=, [4, xy(r).size].max
    assert G.contains?(ring, [0.0, 0.0])
    assert G.ring_inside?(store, ring, 0.01)
    refute G.self_intersects?(ring)
    assert_raises(ArgumentError) { r.simplified(2) }
  end

  def test_circles_and_corners_are_nil_without_premises
    none = Curtilage.generate(PIN, [])

    assert_nil none.enclosing_circle
    assert_nil none.fit_circle
    assert_nil none.simplified(5)
  end

  def test_enclosing_circle_of_points_in_a_line_and_three_points
    assert_equal [[5.0, 0.0], 5.0], G.enclosing_circle([[0.0, 0.0], [10.0, 0.0], [5.0, 0.0]])
    centre, radius = G.enclosing_circle([[0.0, 0.0], [4.0, 0.0], [0.0, 3.0]])

    assert_in_delta 2.5, radius, 1e-9
    assert_in_delta 2.0, centre[0], 1e-9
  end
end
