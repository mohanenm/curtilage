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

  # Same corners as rescanning every triangle each time (ties to the earlier
  # corner), without the time that takes on a big outline.
  def test_simplify_matches_a_full_rescan_and_scales
    rescan = lambda do |xy, max|
      pts = xy.dup
      pts.delete_at((0...pts.size).min_by do |k|
        G.area([pts[k - 1], pts[k], pts[(k + 1) % pts.size]])
      end) while pts.size > max
      pts
    end
    rng = Random.new(5)
    50.times do
      n = rng.rand(4..40)
      ring = Array.new(n) { |i| [Math.cos(2 * Math::PI * i / n), Math.sin(2 * Math::PI * i / n)].map { |v| v * rng.rand(5.0..30.0) } }
      max = rng.rand(3..n)

      assert_equal rescan.call(ring, max), G.simplify(ring, max)
    end
    big = Array.new(5_000) { |i| [Math.cos(i * 0.001257), Math.sin(i * 0.001257)].map { |v| v * (25 + (i % 2 * 0.3)) } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_equal 20, G.simplify(big, 20).size
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  end
end
