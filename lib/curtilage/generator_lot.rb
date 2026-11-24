# frozen_string_literal: true

module Curtilage
  # The lot side of grow_trim: which parking, garages and canopies are the
  # site's, how much of a shared lot to claim, and the driveways to the
  # street. Split from generator.rb only to keep files a readable size.
  module Generator
    module_function

    # Mapped parking that touches the building or holds the pin is the
    # site's lot.
    # A lot touching shared_lot_buildings or more other buildings is a shared
    # (shopping-centre) lot: it isn't this site's alone, so share_lot later
    # claims only the part nearer this building than the others (or centre
    # takes the whole centre, with scope: :centre).
    #
    # Parking garages, carports and canopies next to the building count as
    # lot too (LOT_TYPES). Returns [the site's lots, those of them shared].
    def own_parking(features, target, opts, log)
      structures = features.buildings.select do |b|
        !b.equal?(target) && (LOT_TYPES.include?(b.category) || b.area < opts[:small_building_m2])
      end
      shared = []
      lots = (features.parking + structures + aisles(features, target, opts)).select do |lot|
        next false unless Geometry.contains?(lot.xy, [0.0, 0.0]) || touches?(lot, target, opts)

        others = sharers(lot, features, target, opts)
        shared << lot if others >= opts[:shared_lot_buildings]
        note_lot(log, lot, others, opts)
        true
      end
      [lots, shared]
    end

    # aisle_m: OSM often maps a lot's aisles and driveways as service roads
    # without drawing the lot. A strip aisle_m either side of each service
    # road segment near the building stands in for it (an aisle with stalls
    # both sides is about 9 m each way), then goes through the same claim,
    # sharing, trims and fence as a mapped lot.
    def aisles(features, target, opts)
      width = opts[:aisle_m]
      return [] unless width&.positive?

      reach = opts[:parking_reach_m] + width
      features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }.flat_map do |road|
        road.xy.each_cons(2).with_index.filter_map do |(a, b), i|
          length = Geometry.distance(a, b)
          next if length < 1 || Geometry.closest_points([a, b], target.hull).first > reach

          aisle_strip(a, b, length, width).then do |xy|
            Features::Polygon.new(id: "#{road.id}:#{i}", kind: "parking", xy: xy, area: length * width * 2,
                                  category: "aisle")
          end
        end
      end
    end

    def aisle_strip(a, b, length, width)
      nx = -(b[1] - a[1]) / length * width
      ny = (b[0] - a[0]) / length * width
      Geometry.counter_clockwise([[a[0] + nx, a[1] + ny], [b[0] + nx, b[1] + ny], [b[0] - nx, b[1] - ny],
                                  [a[0] - nx, a[1] - ny]])
    end

    def note_lot(log, lot, others, opts)
      if others >= opts[:shared_lot_buildings]
        log.note("parking #{lot.id} (#{lot.area.round} m2) is shared with #{others} other buildings: " \
                 "claimed the part nearer this building than the others",
                 step: "claim_lot", rule: "shared_lot_buildings", features: [lot.id])
      else
        log.note("#{lot_label(lot)} (#{lot.area.round} m2) touches the building, so it's part of the lot",
                 step: "claim_lot", rule: "parking_reach_m", features: [lot.id], distance_m: opts[:parking_reach_m])
      end
    end

    # Other buildings (not garages or canopies) the lot also touches.
    def sharers(lot, features, target, opts)
      neighbours(features, target, opts).count do |other|
        !LOT_TYPES.include?(other.category) && touches?(lot, other, opts, opts[:lot_share_reach_m])
      end
    end

    # reach: parking_reach_m decides whether a lot is the site's;
    # lot_share_reach_m whether another building shares it.
    def touches?(lot, building, opts, reach = opts[:parking_reach_m])
      return false unless lot.near?(building, reach)

      Geometry.overlap?(lot.xy, building.xy) || Geometry.closest_points(lot.xy, building.xy).first <= reach
    end

    # Claims the site's parking up to the kerb (at most parking_max_extent_m
    # from the building), splitting a lot halfway where it also touches a
    # neighbour, then keeps clear of neighbouring buildings.
    #
    # A shared (shopping-centre) lot is split halfway with each building on
    # it, so the site gets the part nearer to it than to any other; the
    # driveways linking the claimed lot to a public road are taken in.
    def add_parking(poly, lots, site)
      far = fence(site, site.opts[:parking_max_extent_m])
      parts = lots.map { |lot| lot_part(Geometry.clip_convex(lot.xy, far), lot, site) }
      grown = lot_box(poly + parts.select { |p| p.size >= 3 }.flatten(1), far, site.target)
      grown = add_entrances(grown, far, site) unless only_aisles?(lots)
      note_lot_taken(poly, grown, lots, site)
      keep_off_neighbours(grown, site.features, site.target, site.opts, site.log)
    end

    def note_lot_taken(poly, grown, lots, site)
      site.log.note("took in the lot: premises #{m2(poly)} m2 to #{m2(grown)} m2",
                    step: "add_lot", rule: "parking_max_extent_m", features: lots.map(&:id),
                    distance_m: site.opts[:parking_max_extent_m], area_before_m2: m2(poly), area_after_m2: m2(grown))
    end

    # Strips along service roads already reach the kerb; joining a lot of
    # strips alone to each driveway mouth only draws diagonal edges.
    def only_aisles?(lots) = lots.all? { |l| l.category == "aisle" }

    # The rectangle, square to the building, around the premises and the
    # claimed lot, kept inside the fence (roads trimmed). A plain hull would
    # draw a diagonal across the corner wherever the lot reaches the street
    # on one side only; hand-drawn premises are rectangles.
    def lot_box(points, fence, target)
      box = Geometry.oriented_box(points, target.rectangle[:angle])
      Geometry.counter_clockwise(Geometry.clip_convex(box, fence))
    end

    # The box around the building, reach metres out, trimmed at roads.
    def fence(site, reach)
      rect = site.target.rectangle
      box = Geometry.counter_clockwise(Geometry.oriented_box(rect[:corners], rect[:angle], reach))
      trim_at_roads(box, site.features, site.target, site.opts, Log.new([], []))
    end

    # Driveways: service roads that run from the lot to a public road. The
    # part within ENTRANCE_REACH_M of the lot joins the premises, up to the
    # kerb: a short connector to the street gets in, a long service road
    # running along the street (which would pull the polygon into a spike)
    # doesn't.
    def add_entrances(poly, fence, site)
      box = Geometry.bounds(fence)
      points = site.features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }.flat_map do |road|
        # Only roads reaching the fence can be taken in (a cheap test before
        # sampling every road in the area).
        Geometry.bounds_near?(Geometry.bounds(road.xy), box) ? driveway(road, poly, fence, site) : []
      end
      return poly if points.empty?

      Geometry.counter_clockwise(Geometry.convex_hull(poly + points))
    end

    # The points of a service road to take in, or none if it isn't a
    # driveway from the lot to the street.
    def driveway(road, poly, fence, site)
      pts = road.xy.each_cons(2).flat_map { |a, b| samples(a, b) }.select { |p| Geometry.contains?(fence, p) }
      return [] unless pts.any? { |p| Geometry.contains?(poly, p) } && meets_public_road?(pts, site.features)

      site.log.note("took in the driveway #{road.id} to the street", step: "take_driveway", rule: "ENTRANCE_REACH_M",
                                                                     features: [road.id], distance_m: ENTRANCE_REACH_M)
      taken = pts.select { |p| Geometry.contains?(poly, p) || Geometry.distance_to_edges(poly, p) <= ENTRANCE_REACH_M }
      point, street = street_access(taken, site.features)
      site.log.access_point(point, street, road.id) if point
      taken
    end

    # Whether any point comes within ENTRANCE_MAX_M of a public road. Only
    # the roads that reach that close to the points' box are measured.
    def meets_public_road?(points, features)
      return false if points.empty?

      box = Geometry.bounds(points)
      roads = features.public_roads.select { |r| Geometry.bounds_near?(Geometry.bounds(r.xy), box, ENTRANCE_MAX_M) }
      points.any? do |p|
        roads.any? { |r| r.xy.each_cons(2).any? { |a, b| Geometry.segment_distance(p, a, b) <= ENTRANCE_MAX_M } }
      end
    end

    # Where the part of a driveway taken in meets the street: [the point on
    # a public road nearest it, that road], or nil if that's further than
    # ENTRANCE_MAX_M (the driveway reaches the street elsewhere, beyond the
    # premises).
    def street_access(points, features)
      best = points.filter_map { |p| nearest_street(p, features)&.then { |road, q| [p, q, road] } }
                   .min_by { |p, q, _| Geometry.distance(p, q) }
      return nil unless best && Geometry.distance(best[0], best[1]) <= ENTRANCE_MAX_M

      best.drop(1)
    end

    # A lot the site shares with one or two other buildings is still the
    # site's: it is claimed whole, and keep_off_neighbours stays clear of
    # their walls. A shopping-centre lot (shared_lot_buildings or more) is
    # split halfway with each building on it.
    # Homes are the exception: a lot touching one is split halfway with it,
    # so the claim stops short of the yard.
    def share_lot(part, lot, site)
      features, target, opts, log = site.to_a
      shared = site.shared.include?(lot)
      others = lot_neighbours(lot, features, target, opts)
      others.each do |other|
        next unless (shared && !LOT_TYPES.include?(other.category)) || home?(other, features, opts)
        next if part.size < 3

        part = split_from_neighbour(part, target.hull, other.hull, target.rectangle[:angle])
      end
      if others.any?
        log.note("parking #{lot.id} also touches building #{others.map(&:id).join(", ")}",
                 step: "share_lot", features: [lot.id, *others.map(&:id)])
      end
      part
    end

    def lot_part(part, lot, site)
      voronoi = site.opts[:lot_split] == :voronoi && site.shared.include?(lot)
      voronoi ? voronoi_part(part, lot, site) : share_lot(part, lot, site)
    end

    # lot_split: :voronoi. The part of a shared lot nearer this building's
    # walls than any other building's on it (homes included), on a Grid of
    # a metre or two; its convex outline, which lot_box squares up anyway.
    def voronoi_part(part, lot, site)
      features, target, opts, log = site.to_a
      others = lot_neighbours(lot, features, target, opts).reject { |o| LOT_TYPES.include?(o.category) }
      return part if part.size < 3 || others.empty?

      log.note("parking #{lot.id}: claimed the part nearer this building than #{others.size} others on it",
               step: "share_lot", rule: "lot_split", features: [lot.id, *others.map(&:id)])
      hull = nearer_part(part, target.hull, others.map(&:hull))
      hull.size >= 3 ? Geometry.counter_clockwise(hull) : []
    end

    # On a Grid of a metre or two (it's squared up afterwards anyway).
    def nearer_part(part, mine, others)
      extent = Geometry.bounds(part + mine + others.flatten(1))
      cell = ((extent[2] - extent[0]) + (extent[3] - extent[1])).fdiv(600).clamp(1.0, 2.0)
      Grid.new(extent, cell).paint(part).keep_nearer(mine, others).hull
    end

    # Other buildings the lot touches (not ones joined to the site's own),
    # nearest first.
    def lot_neighbours(lot, features, target, opts)
      touching = neighbours(features, target, opts).select do |other|
        touches?(lot, other, opts, opts[:lot_share_reach_m]) && !Geometry.overlap?(other.hull, target.hull)
      end
      nearest_first(touching, target)
    end

    # Stops 1 m short of any neighbouring building the lot reached.
    def keep_off_neighbours(poly, features, target, opts, log)
      area = Geometry.bounds(poly)
      near = neighbours(features, target, opts).select { |other| Geometry.bounds_near?(area, other.bounds) }
      nearest_first(near, target).each do |other|
        next if Geometry.overlap?(other.hull, target.hull) || !Geometry.overlap?(other.hull, poly)

        trimmed = split_from_neighbour(poly, target.hull, other.hull, target.rectangle[:angle],
                                       stop: ->(near, far) { [far - 1, near].max })
        next if trimmed.size < 3

        log.note("stopped 1 m short of building #{other.id}", step: "keep_off_neighbour", features: [other.id],
                                                              distance_m: 1, area_before_m2: m2(poly),
                                                              area_after_m2: m2(trimmed))
        poly = trimmed
      end
      poly
    end

    # scope: :centre on a shared lot: the whole shopping centre, i.e. the
    # shared lots plus every building on them, bounded by public roads.
    def centre(shared, site)
      features, target, opts, log = site.to_a
      members = features.buildings.select do |b|
        b.equal?(target) || (b.area >= opts[:neighbour_min_area_m2] && shared.any? { |lot| touches?(lot, b, opts) })
      end
      points = shared.flat_map(&:xy) + members.flat_map(&:hull)
      poly = trim_at_roads(Geometry.counter_clockwise(Geometry.convex_hull(points)), features, target, opts, log)
      log.flag(:shopping_centre, "mapped the whole shopping centre: #{members.size} buildings around " \
                                 "#{shared.size} shared parking lot(s)",
               step: "whole_centre", features: members.map(&:id) + shared.map(&:id), area_after_m2: m2(poly))
      poly
    end

    def lot_label(lot)
      return "#{lot.category || "small"} structure #{lot.id}" if lot.kind == "building"

      lot.category == "aisle" ? "the strip along service road #{lot.id}" : "parking #{lot.id}"
    end
  end
end
