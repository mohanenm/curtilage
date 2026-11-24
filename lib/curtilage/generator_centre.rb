# frozen_string_literal: true

module Curtilage
  # scope: :centre, the whole shopping centre: from mapped shared lots, or
  # from the service roads joined to the site's where the lot isn't drawn.
  # Split from generator_lot.rb only to keep files a readable size.
  module Generator
    module_function

    # scope: :centre. The whole shopping centre: around the mapped shared
    # lots, or, where OSM maps a centre's lot only as aisles, around the
    # service roads joined to the site's own (centre_network). nil when
    # there's no centre, or it's over centre_max_m2: a regional mall is too
    # coarse to mean "at the store", so the site keeps its own share
    # (flag large_centre).
    def whole_centre(shared, site)
      network = shared.empty?
      shared = centre_network(site) if network
      return nil if shared.empty?

      poly, members = network ? network_centre(shared, site) : centre(shared, site)
      # A lot shared only with homes isn't a shopping centre.
      return nil unless poly && members.size > site.opts[:shared_lot_buildings]
      return note_large_centre(poly, site) if m2(poly) > site.opts[:centre_max_m2]

      site.log.flag(:shopping_centre, "mapped the whole shopping centre: #{members.size} buildings around " \
                                      "#{shared.size} shared lot(s) or aisle strips",
                    step: "whole_centre", features: members.map(&:id) + shared.map(&:id), area_after_m2: m2(poly))
      poly
    end

    def note_large_centre(poly, site)
      limit = site.opts[:centre_max_m2]
      site.log.flag(:large_centre, "the centre is #{m2(poly)} m2, over #{limit} m2: kept the site's own share of it " \
                                   "rather than the whole centre",
                    step: "whole_centre", rule: "centre_max_m2", area_after_m2: m2(poly))
      nil
    end

    # Mapped shared lots: the convex outline of the lots and the buildings on
    # them (homes by a lot aren't part of a centre), trimmed at roads.
    # [outline, members].
    def centre(shared, site)
      features, target, opts, log = site.to_a
      members = features.buildings.select do |b|
        b.equal?(target) || (b.area >= opts[:neighbour_min_area_m2] && !home?(b, features, opts) &&
                             shared.any? { |lot| touches?(lot, b, opts) })
      end
      points = shared.flat_map(&:xy) + members.flat_map(&:hull)
      [trim_at_roads(Geometry.counter_clockwise(Geometry.convex_hull(points)), features, target, opts, log), members]
    end

    # How far from the site the service roads of a centre are followed.
    CENTRE_REACH_M = 150
    # Gaps closed between a centre's aisles and storefronts (a pavement).
    CENTRE_GAP_M = 6

    # The service roads joined (end to end) to those beside the site, within
    # CENTRE_REACH_M and not running past homes (an alley behind houses isn't
    # a centre), as aisle strips: a centre when shared_lot_buildings or more
    # businesses front them. [] otherwise.
    def centre_network(site)
      features, target, opts, = site.to_a
      width = opts[:aisle_m] || 9
      ok = centre_segment_test(features, target, opts, width)
      segments = service_segments(features)
      start = segments.select { |seg| ok.call(seg, opts[:parking_reach_m] + width) }
      strips = joined(start, segments) { |seg| ok.call(seg, CENTRE_REACH_M) }.each_with_index.filter_map do |seg, i|
        network_strip(seg, i, width)
      end
      centre_members(strips, site).size > opts[:shared_lot_buildings] ? strips : []
    end

    # [road id, a, b] for every segment of every service road.
    def service_segments(features)
      features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }.flat_map do |road|
        road.xy.each_cons(2).map { |a, b| [road.id, a, b] }
      end
    end

    # A segment within reach of the site and not running past a home.
    def centre_segment_test(features, target, opts, width)
      homes = features.buildings.select { |b| home?(b, features, opts) }
      near = ->(seg, hull, reach) { Geometry.closest_points(seg[1..], hull).first <= reach }
      lambda do |seg, reach|
        near.call(seg, target.hull, reach) &&
          homes.none? { |h| near.call(seg, h.hull, width + opts[:lot_share_reach_m]) }
      end
    end

    def network_strip((id, a, b), index, width)
      length = Geometry.distance(a, b)
      return nil if length < 1

      Features::Polygon.new(id: "#{id}:n#{index}", kind: "parking", xy: aisle_strip(a, b, length, width),
                            area: length * width * 2, category: "aisle")
    end

    # The site and the businesses (not homes or canopies) fronting the
    # strips, within lot_share_reach_m.
    def centre_members(strips, site)
      features, target, opts, = site.to_a
      [target] + neighbours(features, target, opts).select do |b|
        !LOT_TYPES.include?(b.category) && !home?(b, features, opts) &&
          strips.any? { |s| touches?(s, b, opts, opts[:lot_share_reach_m]) }
      end
    end

    # The segments reachable end to end from start (ends within 2 m), keeping
    # only those the block accepts.
    def joined(start, segments, &accept)
      ends = segments_by_end(segments)
      seen = start.to_h { |seg| [seg, true] }
      queue = start.dup
      until queue.empty?
        next_to(queue.shift, ends).each do |other|
          next if seen[other] || !accept.call(other)

          seen[other] = true
          queue << other
        end
      end
      seen.keys
    end

    def end_key(point) = [(point[0] / 2).floor, (point[1] / 2).floor]

    def segments_by_end(segments)
      segments.each_with_object(Hash.new { |h, k| h[k] = [] }) do |seg, ends|
        [seg[1], seg[2]].each { |p| ends[end_key(p)] << seg }
      end
    end

    def next_to(seg, ends)
      [seg[1], seg[2]].flat_map do |p|
        kx, ky = end_key(p)
        [-1, 0, 1].product([-1, 0, 1]).flat_map { |dx, dy| ends[[kx + dx, ky + dy]] }
      end
    end

    # A centre found from its aisles, outlined round the strips and the
    # buildings fronting them (small gaps closed, homes cut out) rather than
    # a convex hull, which would sweep in unrelated neighbours between them.
    # [outline trimmed at roads, members], or nil.
    def network_centre(strips, site)
      features, target, opts, log = site.to_a
      members = centre_members(strips, site)
      grid = centre_grid(strips.map(&:xy) + members.map(&:hull))
      features.buildings.each { |b| grid.erase(grown_hull(b.hull, NOTCH_GAP_M)) if home?(b, features, opts) }
      return nil unless grid.keep_part?(Geometry.centroid(target.hull))

      xy = Geometry.counter_clockwise(Geometry.douglas_peucker(grid.outline, grid.cell * 1.5))
      return nil if xy.size < 3 || Geometry.self_intersects?(xy)

      [trim_at_roads(xy, features, target, opts, log), members]
    end

    # A grid of a metre or two over the rings, painted, small gaps closed.
    def centre_grid(rings)
      extent = Geometry.bounds(rings.flatten(1))
      cell = ((extent[2] - extent[0]) + (extent[3] - extent[1])).fdiv(500).clamp(1.0, 2.5)
      grid = Grid.new(extent, cell, pad: CENTRE_GAP_M)
      rings.each { |r| grid.paint(r) }
      grid.close(CENTRE_GAP_M)
    end
  end
end
