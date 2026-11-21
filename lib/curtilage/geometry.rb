# frozen_string_literal: true

module Curtilage
  # Plain-Ruby planar geometry. No gems: premises polygons are small (a
  # building and its lot), so a flat projection around the site pin is
  # accurate to well under a metre.
  #
  # Coordinates in and out are [lng, lat], matching GeoJSON. Projected points
  # are [x, y] in metres east and north of an origin. Rings passed around
  # projected are open (no repeated closing point).
  module Geometry
    METRES_PER_DEGREE_LAT = 110_540.0
    METRES_PER_DEGREE_LNG_AT_EQUATOR = 111_320.0

    module_function

    # [lng, lat] points -> [x, y] metres around an origin [lng, lat].
    def project(points, origin)
      lng0, lat0 = origin
      sx = metres_per_degree_lng(lat0)
      points.map { |lng, lat| [(lng - lng0) * sx, (lat - lat0) * METRES_PER_DEGREE_LAT] }
    end

    # Inverse of project.
    def unproject(xy, origin)
      lng0, lat0 = origin
      sx = metres_per_degree_lng(lat0)
      xy.map { |x, y| [lng0 + (x / sx), lat0 + (y / METRES_PER_DEGREE_LAT)] }
    end

    def metres_per_degree_lng(lat)
      Math.cos(lat * Math::PI / 180) * METRES_PER_DEGREE_LNG_AT_EQUATOR
    end

    def closed?(ring)
      ring.size > 1 && ring.first == ring.last
    end

    # The ring without its closing point, whether or not it had one.
    def open_ring(ring)
      closed?(ring) ? ring[0...-1] : ring
    end

    def valid_coordinates?(ring)
      ring.all? { |p| p.is_a?(Array) && p.size == 2 && p.all?(Numeric) && p[0].abs <= 180 && p[1].abs <= 90 }
    end

    # Shoelace area of [x, y] points (open ring), in square metres.
    def area(xy)
      sum = xy.each_index.sum { |i| (xy[i][0] * xy[(i + 1) % xy.size][1]) - (xy[(i + 1) % xy.size][0] * xy[i][1]) }
      (sum / 2.0).abs
    end

    def centroid(xy)
      [xy.sum { |p| p[0] } / xy.size, xy.sum { |p| p[1] } / xy.size]
    end

    # Ray casting. xy is an open ring.
    def contains?(xy, point)
      x, y = point
      inside = false
      xy.each_index do |i|
        x1, y1 = xy[i]
        x2, y2 = xy[(i + 1) % xy.size]
        next unless (y1 > y) != (y2 > y)

        inside = !inside if x < ((x2 - x1) * (y - y1) / (y2 - y1)) + x1
      end
      inside
    end

    # Shortest distance from a point to the ring's edges, in metres.
    def distance_to_edges(xy, point)
      xy.each_index.map { |i| segment_distance(point, xy[i], xy[(i + 1) % xy.size]) }.min
    end

    def segment_distance(point, a, b)
      px, py = point
      ax, ay = a
      bx, by = b
      dx = bx - ax
      dy = by - ay
      len2 = (dx * dx) + (dy * dy)
      t = len2.zero? ? 0 : (((px - ax) * dx) + ((py - ay) * dy)) / len2
      t = t.clamp(0.0, 1.0)
      Math.hypot(px - (ax + (t * dx)), py - (ay + (t * dy)))
    end

    # True when any two non-adjacent edges cross. O(n^2), fine for premises.
    def self_intersects?(xy)
      n = xy.size
      return false if n < 4

      edges = xy.each_index.map { |i| [xy[i], xy[(i + 1) % n]] }
      edges.each_index.any? do |i|
        ((i + 2)...n).any? do |j|
          next false if i.zero? && j == n - 1 # first and last edge share a vertex

          segments_cross?(*edges[i], *edges[j])
        end
      end
    end

    def segments_cross?(p1, p2, p3, p4)
      d1 = cross(p3, p4, p1)
      d2 = cross(p3, p4, p2)
      d3 = cross(p1, p2, p3)
      d4 = cross(p1, p2, p4)
      ((d1.positive? && d2.negative?) || (d1.negative? && d2.positive?)) &&
        ((d3.positive? && d4.negative?) || (d3.negative? && d4.positive?))
    end

    def cross(o, a, b)
      ((a[0] - o[0]) * (b[1] - o[1])) - ((a[1] - o[1]) * (b[0] - o[0]))
    end

    # Andrew's monotone chain. Returns the hull as an open ring.
    def convex_hull(xy)
      pts = xy.uniq.sort
      return pts if pts.size < 3

      lower = []
      pts.each do |p|
        lower.pop while lower.size >= 2 && cross(lower[-2], lower[-1], p) <= 0
        lower << p
      end
      upper = []
      pts.reverse_each do |p|
        upper.pop while upper.size >= 2 && cross(upper[-2], upper[-1], p) <= 0
        upper << p
      end
      lower[0...-1] + upper[0...-1]
    end

    # Minimum-area bounding rectangle, trying each hull edge direction.
    # Returns { corners:, area:, angle: } with angle in radians, or nil when
    # the points don't span an area.
    def minimum_rectangle(xy)
      hull = convex_hull(xy)
      return nil if hull.size < 3

      best = hull.each_index.map do |i|
        a = hull[i]
        b = hull[(i + 1) % hull.size]
        angle = Math.atan2(b[1] - a[1], b[0] - a[0])
        box = oriented_box(hull, angle)
        { corners: box, area: area(box), angle: angle }
      end
      best.min_by { |r| r[:area] }
    end

    # [area_m2, orientation_degrees_0_to_180] of the minimum rectangle.
    def min_rotated_rectangle(xy)
      rect = minimum_rectangle(xy)
      return [0.0, 0.0] unless rect

      [rect[:area], (rect[:angle] * 180 / Math::PI) % 180]
    end

    # The box around the points with sides parallel and perpendicular to
    # angle (radians), grown by margin metres on every side. Counter-clockwise.
    def oriented_box(xy, angle, margin = 0)
      local = rotate(xy, -angle)
      xs = local.map(&:first)
      ys = local.map(&:last)
      x0 = xs.min - margin
      x1 = xs.max + margin
      y0 = ys.min - margin
      y1 = ys.max + margin
      rotate([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], angle)
    end

    def rotate(xy, angle)
      cos = Math.cos(angle)
      sin = Math.sin(angle)
      xy.map { |x, y| [(x * cos) - (y * sin), (x * sin) + (y * cos)] }
    end

    def signed_area(xy)
      xy.each_index.sum { |i| (xy[i][0] * xy[(i + 1) % xy.size][1]) - (xy[(i + 1) % xy.size][0] * xy[i][1]) } / 2.0
    end

    def counter_clockwise(xy)
      signed_area(xy).negative? ? xy.reverse : xy
    end

    # Centre of mass of the polygon's area (the vertex mean is biased toward
    # densely sampled edges).
    def area_centroid(xy)
      a = signed_area(xy)
      return centroid(xy) if a.abs < 1e-9

      cx = 0.0
      cy = 0.0
      xy.each_index do |i|
        x1, y1 = xy[i]
        x2, y2 = xy[(i + 1) % xy.size]
        f = (x1 * y2) - (x2 * y1)
        cx += (x1 + x2) * f
        cy += (y1 + y2) * f
      end
      [cx / (6 * a), cy / (6 * a)]
    end

    # Keeps the part of the polygon where (p - origin) . normal <= 0
    # (Sutherland-Hodgman against one line). Works for any simple polygon;
    # a non-convex input can come back with zero-width bridges, which don't
    # change its area.
    def clip_half_plane(xy, origin, normal)
      sides = xy.map { |p| dot([p[0] - origin[0], p[1] - origin[1]], normal) }
      xy.each_index.with_object([]) do |i, out|
        j = (i + 1) % xy.size
        out << xy[i] if sides[i] <= 0
        out << lerp(xy[i], xy[j], sides[i].fdiv(sides[i] - sides[j])) if (sides[i] * sides[j]).negative?
      end
    end

    def dot(a, b)
      (a[0] * b[0]) + (a[1] * b[1])
    end

    def lerp(a, b, fraction)
      [a[0] + (fraction * (b[0] - a[0])), a[1] + (fraction * (b[1] - a[1]))]
    end

    # The part of subject inside a convex clipper.
    def clip_convex(subject, clipper)
      clipper = counter_clockwise(clipper)
      clipper.each_index.reduce(subject) do |poly, i|
        break [] if poly.size < 3

        a = clipper[i]
        b = clipper[(i + 1) % clipper.size]
        clip_half_plane(poly, a, [b[1] - a[1], a[0] - b[0]])
      end
    end

    def closest_point_on_segment(point, a, b)
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      len2 = (dx * dx) + (dy * dy)
      t = len2.zero? ? 0 : ((((point[0] - a[0]) * dx) + ((point[1] - a[1]) * dy)) / len2).clamp(0.0, 1.0)
      [a[0] + (t * dx), a[1] + (t * dy)]
    end

    # The nearest pair of boundary points of two polygons: [distance, on_a, on_b].
    # Assumes they don't overlap (check with overlap? first).
    def closest_points(poly_a, poly_b)
      candidates = []
      [[poly_a, poly_b, false], [poly_b, poly_a, true]].each do |from, to, flipped|
        from.each do |p|
          to.each_index do |i|
            q = closest_point_on_segment(p, to[i], to[(i + 1) % to.size])
            candidates << (if flipped
                             [Math.hypot(p[0] - q[0], p[1] - q[1]), q,
                              p]
                           else
                             [Math.hypot(p[0] - q[0], p[1] - q[1]), p, q]
                           end)
          end
        end
      end
      candidates.min_by(&:first)
    end

    # [min_x, min_y, max_x, max_y].
    def bounds(xy)
      xs = xy.map(&:first)
      ys = xy.map(&:last)
      [xs.min, ys.min, xs.max, ys.max]
    end

    # Whether two bounds come within margin of each other: a cheap test
    # before the exact ones.
    def bounds_near?(a, b, margin = 0)
      a[0] - margin <= b[2] && b[0] - margin <= a[2] && a[1] - margin <= b[3] && b[1] - margin <= a[3]
    end

    def overlap?(poly_a, poly_b)
      return true if poly_a.any? { |p| contains?(poly_b, p) } || poly_b.any? { |p| contains?(poly_a, p) }

      poly_a.each_index.any? do |i|
        a1 = poly_a[i]
        a2 = poly_a[(i + 1) % poly_a.size]
        poly_b.each_index.any? { |j| segments_cross?(a1, a2, poly_b[j], poly_b[(j + 1) % poly_b.size]) }
      end
    end

    # Drops the vertices that matter least (smallest triangle with their
    # neighbours) until at most max remain. On a convex polygon this only
    # cuts corners, so the result stays convex and inside the original.
    def simplify(xy, max)
      pts = xy.dup
      while pts.size > max
        n = pts.size
        i = (0...n).min_by { |k| area([pts[(k - 1) % n], pts[k], pts[(k + 1) % n]]) }
        pts.delete_at(i)
      end
      pts
    end

    # Like simplify, but only drops a vertex if the polygon still contains
    # every point in keep (e.g. a building's corners). Stops early, above
    # max, if no vertex can go.
    def simplify_containing(xy, max, keep)
      pts = xy.dup
      while pts.size > max
        n = pts.size
        candidates = (0...n).sort_by { |k| area([pts[(k - 1) % n], pts[k], pts[(k + 1) % n]]) }
        drop = candidates.find do |k|
          trial = pts.dup.tap { |t| t.delete_at(k) }
          keep.all? { |p| contains?(trial, p) || distance_to_edges(trial, p) < 0.01 }
        end
        break unless drop

        pts.delete_at(drop)
      end
      pts
    end

    # The part of subject inside a convex clipper shrunk by margin metres.
    def clip_inside(subject, clipper, margin)
      clipper = counter_clockwise(clipper)
      clipper.each_index.reduce(subject) do |poly, i|
        break [] if poly.size < 3

        a = clipper[i]
        b = clipper[(i + 1) % clipper.size]
        normal = [b[1] - a[1], a[0] - b[0]]
        length = Math.hypot(*normal)
        next poly if length < 1e-9

        unit = normal.map { |v| v / length }
        clip_half_plane(poly, [a[0] - (unit[0] * margin), a[1] - (unit[1] * margin)], unit)
      end
    end

    # Removes repeated and collinear points (within tolerance metres).
    def clean(xy, tolerance = 0.05)
      pts = drop_repeats(xy, tolerance)
      loop do
        n = pts.size
        break if n < 4

        i = (0...n).find { |k| segment_distance(pts[k], pts[(k - 1) % n], pts[(k + 1) % n]) < tolerance }
        break unless i

        pts.delete_at(i)
      end
      pts
    end

    def drop_repeats(xy, tolerance)
      near = ->(p, q) { Math.hypot(p[0] - q[0], p[1] - q[1]) < tolerance }
      pts = xy.each_with_object([]) { |p, out| out << p unless out.last && near.call(p, out.last) }
      pts.pop while pts.size > 1 && near.call(pts[0], pts[-1])
      pts
    end
  end
end
