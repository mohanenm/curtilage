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
        at_pin = Geometry.contains?(lot.xy, [0.0, 0.0])
        next false unless at_pin || touches?(lot, target, opts)

        others = sharers(lot, features, target, opts)
        if others >= opts[:shared_lot_buildings]
          # A store shares a lot the way its neighbours do: by fronting it.
          # One across an aisle or a planting strip belongs to the others.
          next false unless at_pin || touches?(lot, target, opts, opts[:lot_share_reach_m])

          shared << lot
        end
        note_lot(log, lot, others, opts)
        true
      end
      [lots, shared]
    end

    # Mapped parking that isn't the site's (not claimed, not at the pin) is
    # another business's lot: the premises stop at its edge, as they stop
    # short of a neighbour's building. Without this the first 30 m of growth
    # runs into it whenever it lies across an aisle or a planting strip.
    def keep_off_other_lots(poly, features, target, lots, log)
      return poly unless poly

      features.parking.each do |lot|
        next if lots.include?(lot) || Geometry.contains?(lot.xy, [0.0, 0.0]) || !Geometry.overlap?(lot.hull, poly)
        next if Geometry.overlap?(lot.hull, target.hull)

        cut = split_from_neighbour(poly, target.hull, lot.hull, target.rectangle[:angle], stop: ->(_near, far) { far })
        next if cut.size < 3 || takes_own_lot?(poly, cut, lots, lot.hull)

        log.note("stopped at parking #{lot.id}, another business's lot",
                 step: "keep_off_lot", features: [lot.id], area_before_m2: m2(poly), area_after_m2: m2(cut))
        poly = cut
      end
      poly
    end

    # A cut at another business's lot may drop the site's claimed lots
    # (parking, aisle strips) only where they run into that lot: never the
    # site's own lot or drive-through elsewhere.
    def takes_own_lot?(poly, cut, lots, other)
      rings = lots.map(&:xy)
      inside = rings.map { |r| Geometry.clip_convex(r, other) }.select { |r| r.size >= 3 }
      lost = held_area(poly, rings) - held_area(cut, rings)
      lost > held_area(poly, inside) + (0.02 * held_area(poly, rings)) + 1
    end

    def held_area(poly, rings)
      xy = Geometry.counter_clockwise(poly)
      rings.sum { |r| Geometry.overlap_area(xy, Geometry.counter_clockwise(r)) }
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
        text = "parking #{lot.id} (#{lot.area.round} m2) is shared with #{others} other buildings: " \
               "claimed the part nearer this building than the others"
        args = { step: "claim_lot", rule: "shared_lot_buildings", features: [lot.id] }
        # With scope: :centre the whole lot is taken, so nothing was split.
        opts[:scope] == :centre ? log.note(text, **args) : log.flag(:shared_lot, text, **args)
      elsif opts[:shared_checks] && others >= SHARED_CHECK_OTHERS
        log.flag(:shared_lot, "#{lot_label(lot)} (#{lot.area.round} m2) touches the building and #{others} other " \
                              "building(s): claimed whole, but it may be shared",
                 step: "claim_lot", rule: "shared_checks", features: [lot.id])
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
      parts = lots.map { |lot| share_lot(Geometry.clip_convex(lot.xy, far), lot, site) }
      grown = keep_claimed(poly, lot_box(poly + parts.select { |p| p.size >= 3 }.flatten(1), far, site.target))
      grown = add_entrances(grown, far, site) unless only_aisles?(lots)
      note_lot_taken(poly, grown, lots, site)
      keep_off_neighbours(grown, site.features, site.target, site.opts, site.log)
    end

    # Taking in the lot never gives up ground the premises already held. The
    # fence reaches further than the first trim, so a road beyond it can cut
    # the fence along a line that runs back through the premises (which line
    # depends on the pin, so a pin moved 3 m could lose half the lot): then
    # the outline round both is kept.
    def keep_claimed(poly, grown)
      return grown if grown.size >= 3 && Geometry.overlap_area(poly, grown) >= Geometry.area(poly) - 1

      Geometry.counter_clockwise(Geometry.convex_hull(poly + grown))
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
      nearest_first(near, target).each { |other| poly = line_off_neighbour(poly, other, target, log) }
      poly
    end

    def line_off_neighbour(poly, other, target, log)
      return poly if Geometry.overlap?(other.hull, target.hull) || !Geometry.overlap?(other.hull, poly)

      trimmed = split_from_neighbour(poly, target.hull, other.hull, target.rectangle[:angle],
                                     stop: ->(near, far) { [far - 1, near].max })
      return poly if trimmed.size < 3

      log.note("stopped 1 m short of building #{other.id}", step: "keep_off_neighbour", features: [other.id],
                                                            distance_m: 1, area_before_m2: m2(poly),
                                                            area_after_m2: m2(trimmed))
      trimmed
    end

    # Corners non-convex premises may keep: max_vertices, plus four for
    # each entrance taken in.
    def outline_budget(opts, log)
      extra = log.steps.to_a.any? { |s| s[:step] == "take_entrance" } ? 4 * (log.access || []).size : 0
      # A whole centre traced round its aisles isn't a rectangle.
      extra = Validation::DEFAULTS[:max_vertices] if log.steps.to_a.any? { |s| s[:step] == "whole_centre" }
      [opts[:max_vertices] + extra, Validation::DEFAULTS[:max_vertices]].min
    end

    NOTCH_GAP_M = 1 # homes are kept this far clear when a centre is traced

    # A convex ring metres outside a convex hull (corners cut at 45 degrees).
    def grown_hull(hull, metres)
      d = metres / Math.sqrt(2)
      Geometry.convex_hull(hull.flat_map do |x, y|
        [[x + metres, y], [x - metres, y], [x, y + metres], [x, y - metres],
         [x + d, y + d], [x - d, y + d], [x + d, y - d], [x - d, y - d]]
      end)
    end

    def lot_label(lot)
      return "#{lot.category || "small"} structure #{lot.id}" if lot.kind == "building"

      lot.category == "aisle" ? "the strip along service road #{lot.id}" : "parking #{lot.id}"
    end
  end
end
