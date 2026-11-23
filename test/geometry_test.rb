# frozen_string_literal: true

require_relative "test_helper"

class GeometryTest < Minitest::Test
  G = Curtilage::Geometry
  SQUARE = [[0, 0], [10, 0], [10, 10], [0, 10]].freeze

  def test_project_and_unproject_round_trip
    pts = [[-80.001, 35.002], [-79.999, 34.998]]
    back = G.unproject(G.project(pts, [-80.0, 35.0]), [-80.0, 35.0])

    pts.zip(back).each { |a, b| a.zip(b).each { |u, v| assert_in_delta u, v, 1e-12 } }
  end

  def test_round_buffer_keeps_its_distance
    grown = G.round_buffer(SQUARE, 5)

    assert(SQUARE.all? { |p| G.distance_to_edges(grown, p) >= 5 - 1e-9 })
    # A 10 m square grown by 5 m is about 378.5 m2; the 16-sided corners sit
    # just outside the circle, adding a few m2.
    assert_in_delta 383.5, G.area(grown), 1
    assert_equal SQUARE, G.round_buffer(SQUARE, 0)
  end

  def test_minimum_rectangle_of_a_rotated_rectangle
    rect = G.rotate([[0, 0], [30, 0], [30, 10], [0, 10]], 0.5)
    result = G.minimum_rectangle(rect)

    assert_in_delta 300, result[:area], 1e-6
    assert_in_delta 0.5, result[:angle] % (Math::PI / 2), 1e-9
  end

  def test_oriented_box_with_margin
    assert_in_delta 400, G.area(G.oriented_box(SQUARE, 0, 5)), 1e-9
  end

  def test_clip_half_plane_and_convex
    assert_in_delta 50, G.area(G.clip_half_plane(SQUARE, [5, 0], [1, 0])), 1e-9
    l_shape = [[0, 0], [20, 0], [20, 10], [10, 10], [10, 20], [0, 20]]

    assert_in_delta 75, G.area(G.clip_convex(l_shape, [[5, 5], [15, 5], [15, 15], [5, 15]])), 1e-9
  end

  def test_closest_points_and_overlap
    other = [[15, 0], [20, 0], [20, 10], [15, 10]]
    distance, = G.closest_points(SQUARE, other)

    assert_in_delta 5, distance, 1e-9
    refute G.overlap?(SQUARE, other)
    assert G.overlap?(SQUARE, [[5, 5], [15, 5], [15, 15], [5, 15]])
  end

  def test_simplify
    octagon = (0...8).map { |i| [Math.cos(i * Math::PI / 4), Math.sin(i * Math::PI / 4)] }

    assert_equal 5, G.simplify(octagon, 5).size
  end

  def test_the_sweep_agrees_with_checking_every_pair
    pairwise = lambda do |xy|
      n = xy.size
      edges = xy.each_index.map { |i| [xy[i], xy[(i + 1) % n]] }
      (0...n).any? do |i|
        ((i + 2)...n).any? { |j| !(i.zero? && j == n - 1) && G.segments_cross?(*edges[i], *edges[j]) }
      end
    end
    rng = Random.new(7)
    300.times do
      xy = Array.new(rng.rand(9..30)) { [rng.rand(-50..50), rng.rand(-50..50)] }

      assert_equal pairwise.call(xy), G.self_intersects?(xy), xy.inspect
    end
    star = Array.new(10) do |k|
      radius = k.even? ? 20 : 8
      [Math.cos(k * Math::PI / 5) * radius, Math.sin(k * Math::PI / 5) * radius]
    end

    refute G.self_intersects?(star), "a simple 10-pointed star"
  end
end
