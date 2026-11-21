# frozen_string_literal: true

# Plain-Ruby planar geometry. No gems: premises polygons are small (a building
# and its lot), so a flat projection around the site pin is accurate to well
# under a metre.
#
# Coordinates in and out are [lng, lat], matching GeoJSON.
module Curtilage
  module Geometry
    METRES_PER_DEGREE_LAT = 110_540.0
    METRES_PER_DEGREE_LNG_AT_EQUATOR = 111_320.0

    module_function

    # [lng, lat] points -> [x, y] metres around an origin [lng, lat].
    def project(points, origin)
      lng0, lat0 = origin
      scale_x = Math.cos(lat0 * Math::PI / 180) * METRES_PER_DEGREE_LNG_AT_EQUATOR
      points.map { |lng, lat| [(lng - lng0) * scale_x, (lat - lat0) * METRES_PER_DEGREE_LAT] }
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

    # Minimum-area bounding rectangle over the hull's edge directions.
    # Returns [area_m2, orientation_degrees_0_to_180].
    def min_rotated_rectangle(xy)
      hull = convex_hull(xy)
      return [0.0, 0.0] if hull.size < 3

      hull.each_index.map { |i|
        a = hull[i]
        b = hull[(i + 1) % hull.size]
        angle = Math.atan2(b[1] - a[1], b[0] - a[0])
        cos = Math.cos(-angle)
        sin = Math.sin(-angle)
        rotated = hull.map { |x, y| [(x * cos) - (y * sin), (x * sin) + (y * cos)] }
        xs = rotated.map(&:first)
        ys = rotated.map(&:last)
        [(xs.max - xs.min) * (ys.max - ys.min), (angle * 180 / Math::PI) % 180]
      }.min_by(&:first)
    end
  end
end
