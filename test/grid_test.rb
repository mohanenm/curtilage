# frozen_string_literal: true

require_relative "test_helper"

# Grid (raster unions and outlines) and the exact any-shape ring helpers.
class GridTest < Minitest::Test
  G = Curtilage::Geometry
  L_SHAPE = [[0, 0], [20, 0], [20, 10], [10, 10], [10, 20], [0, 20]].freeze

  def grid(pad: 0) = Curtilage::Grid.new([0, 0, 40, 30], 0.5, pad: pad)

  def test_union_and_outline_of_touching_rectangles
    g = grid.paint([[0, 0], [20, 0], [20, 10], [0, 10]]).paint([[20, 0], [30, 0], [30, 20], [20, 20]])

    assert g.keep_part?([5, 5])
    outline = g.outline

    assert_in_delta 400, G.area(outline), 1e-9
    assert_equal 6, outline.size
    refute G.self_intersects?(outline)
    assert_operator G.signed_area(outline), :>, 0
  end

  # A wall from the bottom edge to y = 20 at x = 10-11: the path from the
  # source to (20, 2) goes round its top, about twice as far.
  def test_path_distance_goes_round_a_blocked_wall
    g = Curtilage::Grid.new([0, 0, 30, 30], 1.0)
    source = g.painted([[[1.5, 1.5], [2.5, 1.5], [2.5, 2.5], [1.5, 2.5]]])
    wall = g.painted([[[10, -5], [11, -5], [11, 20], [10, 20]]])
    open = g.path_distance(source, Array.new(source.size, false), 100)
    round = g.path_distance(source, wall, 100)
    at = ->(dist, x, y) { dist[((y + 2).floor * 34) + (x + 2).floor] }

    assert_in_delta 19.4, at.call(open, 20, 2), 0.1 # cell centres (1.5, 1.5) to (20.5, 2.5)
    assert_in_delta 2 * 18.5 * 1.1, at.call(round, 20, 2), 6
    assert_equal Float::INFINITY, at.call(g.path_distance(source, wall, 10), 20, 2)
  end

  def test_erase_cuts_a_notch_and_fills_holes
    g = grid.paint([[0, 0], [30, 0], [30, 20], [0, 20]]).erase([[20, 10], [31, 10], [31, 21], [20, 21]])
    g.erase([[5, 5], [8, 5], [8, 8], [5, 8]]) # a hole: filled again

    g.keep_part?([1, 1])

    assert_in_delta 600 - 100, G.area(g.outline), 1e-9
  end

  def test_keep_part_drops_other_parts_and_corner_touches
    g = grid.paint([[0, 0], [10, 0], [10, 10], [0, 10]]).paint([[20, 0], [30, 0], [30, 10], [20, 10]])

    refute g.keep_part?([15, 5])
    assert g.keep_part?([5, 5])
    assert_in_delta 100, g.area, 1e-9

    pinch = grid.paint([[0, 0], [10, 0], [10, 10], [0, 10]]).paint([[10, 10], [20, 10], [20, 20], [10, 20]])
    pinch.keep_part?([5, 5]) # joined only at a corner: not the same part

    assert_in_delta 100, pinch.area, 1e-9
    refute G.self_intersects?(pinch.outline)
  end

  def test_close_bridges_narrow_gaps_only
    g = grid(pad: 3).paint([[0, 0], [20, 0], [20, 10], [0, 10]]).paint([[24, 0], [40, 0], [40, 10], [24, 10]])
    g.close(3)

    assert g.keep_part?([5, 5])
    outline = g.outline
    assert G.contains?(outline, [22, 5]) # the gap is bridged: one part
    refute G.contains?(outline, [22, 0.2]) # the gap's corners round off
    assert_raises(ArgumentError) { grid.close(5) }
  end

  def test_triangulate_and_overlap_area
    assert_in_delta 300, G.triangulate(L_SHAPE).sum { |t| G.area(t) }, 1e-9
    assert_in_delta 75, G.overlap_area([[5, 5], [15, 5], [15, 15], [5, 15]], L_SHAPE), 1e-9
    assert_in_delta 75, G.overlap_area(L_SHAPE, [[5, 5], [15, 5], [15, 15], [5, 15]]), 1e-9
    assert G.convex?([[0, 0], [1, 0], [1, 1]])
    refute G.convex?(L_SHAPE)
  end

  def test_ring_inside_with_margin
    outer = L_SHAPE

    assert G.ring_inside?([[1, 1], [9, 1], [9, 9], [1, 9]], outer, 0.5)
    refute G.ring_inside?([[1, 1], [9, 1], [9, 9], [1, 9]], outer, 1.5)
    refute G.ring_inside?([[5, 5], [15, 5], [15, 15], [5, 15]], outer) # crosses the notch
    refute G.ring_inside?([[8, 8], [12, 8], [12, 12], [8, 12]], outer) # notch corner pokes in
  end

  def test_simplify_around_keeps_inner_ring_and_stays_simple
    stairs = (0..10).flat_map { |k| [[k * 2.0, k * 2.0], [(k * 2.0) + 2, k * 2.0]] }
    ring = [[0.0, -5.0], [30.0, -5.0], [30.0, 22.0]] + stairs.reverse
    inner = [[20, -3], [25, -3], [25, 2], [20, 2]]
    simple = G.simplify_around(ring, 5, [inner], 0.5)

    assert_operator simple.size, :<=, 5
    refute G.self_intersects?(simple)
    assert G.ring_inside?(inner, simple, 0.5)
  end

  def test_douglas_peucker_straightens_a_staircase
    stairs = [[0.0, 0.0], [10.0, 0.0]] + (0..9).flat_map { |k| [[10.0 - k, 10.0 - k], [9.0 - k, 10.0 - k]] }

    assert_equal 3, G.douglas_peucker(stairs, 1.0).size
  end
end
