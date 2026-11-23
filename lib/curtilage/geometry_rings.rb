# frozen_string_literal: true

module Curtilage
  # Exact operations on simple rings of any shape (not only convex ones):
  # overlap areas, containment with a clearance and simplification that
  # keeps given points inside. Split from geometry.rb only to keep files a
  # readable size.
  module Geometry
    module_function

    def convex?(xy)
      n = xy.size
      return false if n < 3

      turns = n.times.map { |i| cross(xy[i], xy[(i + 1) % n], xy[(i + 2) % n]) }
      turns.all? { |t| t >= -1e-9 } || turns.all? { |t| t <= 1e-9 }
    end

    # Ear clipping: the ring (simple, open) as triangles covering it exactly.
    # A ring too degenerate to clip (no ear left) ends in a fan, which still
    # covers it when it is nearly convex.
    def triangulate(xy)
      pts = counter_clockwise(clean(xy, 1e-6))
      return [] if pts.size < 3

      triangles = []
      while pts.size > 3
        i = (0...pts.size).find { |k| ear?(pts, k) }
        break unless i

        triangles << [pts[(i - 1) % pts.size], pts[i], pts[(i + 1) % pts.size]]
        pts.delete_at(i)
      end
      triangles + (1...(pts.size - 1)).map { |k| [pts[0], pts[k], pts[k + 1]] }
    end

    def ear?(pts, index)
      a = pts[(index - 1) % pts.size]
      b = pts[index]
      c = pts[(index + 1) % pts.size]
      return false unless cross(a, b, c) > 1e-12

      pts.none? { |p| !p.equal?(a) && !p.equal?(b) && !p.equal?(c) && in_triangle?(p, a, b, c) }
    end

    def in_triangle?(point, a, b, corner)
      cross(a, b, point) >= 0 && cross(b, corner, point) >= 0 && cross(corner, a, point) >= 0
    end

    # Area shared by two simple rings of any shape: the subject clipped by
    # each triangle of the other (a convex one is used whole).
    def overlap_area(subject, other)
      other = counter_clockwise(other)
      pieces = convex?(other) ? [other] : triangulate(other)
      pieces.sum do |piece|
        part = clip_convex(subject, piece)
        part.size >= 3 ? area(part) : 0
      end
    end

    # Whether inner lies inside outer (both simple rings) and at least
    # margin metres from its edges. Two rings whose edges don't cross are
    # nested when a vertex of one is inside the other; the gap between their
    # boundaries is always reached at a vertex of one of them.
    def ring_inside?(inner, outer, margin = 0)
      return false unless contains?(outer, inner[0])

      inner.all? { |p| contains?(outer, p) && distance_to_edges(outer, p) >= margin } &&
        outer.all? { |q| !contains?(inner, q) && distance_to_edges(inner, q) >= margin } &&
        !rings_cross?(inner, outer)
    end

    def rings_cross?(xy_a, xy_b)
      xy_a.each_index.any? do |i|
        a1 = xy_a[i]
        a2 = xy_a[(i + 1) % xy_a.size]
        xy_b.each_index.any? { |j| segments_cross?(a1, a2, xy_b[j], xy_b[(j + 1) % xy_b.size]) }
      end
    end

    # Douglas-Peucker on a closed ring: drops points less than tolerance
    # metres off the line through their neighbours. Splits at the two points
    # furthest apart so the ring's ends aren't treated as fixed corners.
    def douglas_peucker(xy, tolerance)
      return xy if xy.size < 4

      far = (1...xy.size).max_by { |i| distance(xy[0], xy[i]) }
      first = dp_chain(xy[0..far], tolerance)
      second = dp_chain(xy[far..] + [xy[0]], tolerance)
      first[0...-1] + second[0...-1]
    end

    def dp_chain(chain, tolerance)
      keep = Array.new(chain.size, false)
      keep[0] = keep[-1] = true
      stack = [[0, chain.size - 1]]
      until stack.empty?
        lo, hi = stack.pop
        next if hi - lo < 2

        far, d = ((lo + 1)...hi).map { |i| [i, segment_distance(chain[i], chain[lo], chain[hi])] }.max_by(&:last)
        next unless d > tolerance

        keep[far] = true
        stack << [lo, far] << [far, hi]
      end
      chain.select.with_index { |_, i| keep[i] }
    end

    # Drops the vertices that matter least (smallest triangle with their
    # neighbours) until at most max remain, but only while the ring stays
    # simple and still holds each of the inners (rings) margin metres
    # inside. Works on any simple ring; may stop above max when no vertex
    # can go.
    # The inners must be inside to begin with.
    def simplify_around(xy, max, inners, margin)
      pts = counter_clockwise(xy)
      while pts.size > max
        n = pts.size
        order = (0...n).sort_by { |k| area([pts[(k - 1) % n], pts[k], pts[(k + 1) % n]]) }
        drop = order.find { |k| droppable?(pts, k, inners, margin) }
        break unless drop

        pts = pts.dup.tap { |t| t.delete_at(drop) }
      end
      pts
    end

    # Dropping corner k changes only the triangle it makes with its
    # neighbours: a reflex corner adds it (the inners stay inside), a convex
    # one cuts it off, which must miss each inner by margin. Either way the
    # new edge mustn't cross the ring.
    def droppable?(pts, index, inners, margin)
      n = pts.size
      a = pts[(index - 1) % n]
      v = pts[index]
      b = pts[(index + 1) % n]
      trial = pts.dup.tap { |t| t.delete_at(index) }
      return false if edge_crosses_ring?(trial, (index - 1) % trial.size)

      cross(a, v, b).negative? || inners.all? { |ring| clear_of_cut?(ring, [a, v, b], margin) }
    end

    # Whether a ring that was inside stays margin metres inside once the
    # triangle [a, v, b] is cut off along a-b.
    def clear_of_cut?(ring, triangle, margin)
      a, v, b = triangle
      ring.none? { |p| in_triangle?(p, a, v, b) } &&
        ring.each_index.none? { |i| segments_cross?(a, b, ring[i], ring[(i + 1) % ring.size]) } &&
        ring.all? { |p| segment_distance(p, a, b) >= margin } &&
        [a, b].all? { |q| distance_to_edges(ring, q) >= margin }
    end

    # Any simple ring grown (positive metres) or shrunk (negative) evenly, on
    # a Grid: the outline round the part holding point, straightened to
    # within a cell, or nil if nothing is left there. An extra cell either
    # way keeps straightening from undoing the buffer (a grown ring still
    # holds the input, a shrunk one stays inside it).
    def buffer_any(xy, metres, point)
      cell = (Math.sqrt(area(xy) + (metres.abs * metres.abs)) / 200).clamp(0.5, 2.0)
      grid = Grid.new(bounds(xy), cell, pad: metres.abs + (2 * cell)).paint(xy)
      grid.buffer(metres.positive? ? metres + cell : metres - cell)
      return nil unless grid.keep_part?(point)

      ring = douglas_peucker(grid.outline, cell)
      ring.size >= 3 && !self_intersects?(ring) ? ring : nil
    end

    # Whether edge i of the ring crosses any edge not next to it.
    def edge_crosses_ring?(xy, index)
      n = xy.size
      a = xy[index]
      b = xy[(index + 1) % n]
      (0...n).any? do |j|
        next false if j == index || adjacent?(j - index, n)

        segments_cross?(a, b, xy[j], xy[(j + 1) % n])
      end
    end
  end
end
