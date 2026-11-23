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
      lots = (features.parking + structures).select do |lot|
        next false unless Geometry.contains?(lot.xy, [0.0, 0.0]) || touches?(lot, target, opts)

        others = sharers(lot, features, target, opts)
        if others >= opts[:shared_lot_buildings]
          shared << lot
          log.note("parking #{lot.id} (#{lot.area.round} m2) is shared with #{others} other buildings: " \
                   "claimed the part nearer this building than the others")
        else
          log.note("#{lot_label(lot)} (#{lot.area.round} m2) touches the building, so it's part of the lot")
        end
        true
      end
      [lots, shared]
    end

    # Other buildings (not garages or canopies) the lot also touches.
    def sharers(lot, features, target, opts)
      neighbours(features, target, opts).count do |other|
        !LOT_TYPES.include?(other.category) && touches?(lot, other, opts)
      end
    end

    def touches?(lot, building, opts)
      return false unless lot.near?(building, opts[:parking_reach_m])

      Geometry.overlap?(lot.xy, building.xy) ||
        Geometry.closest_points(lot.xy, building.xy).first <= opts[:parking_reach_m]
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
      grown = lot_box(poly + parts.select { |p| p.size >= 3 }.flatten(1), far, site.target)
      grown = add_entrances(grown, far, site)
      keep_off_neighbours(grown, site.features, site.target, site.opts, site.log)
    end

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
      points = site.features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }.flat_map do |road|
        driveway(road, poly, fence, site)
      end
      return poly if points.empty?

      Geometry.counter_clockwise(Geometry.convex_hull(poly + points))
    end

    # The points of a service road to take in, or none if it isn't a
    # driveway from the lot to the street.
    def driveway(road, poly, fence, site)
      pts = road.xy.each_cons(2).flat_map { |a, b| samples(a, b) }.select { |p| Geometry.contains?(fence, p) }
      return [] unless pts.any? { |p| Geometry.contains?(poly, p) } && meets_public_road?(pts, site.features)

      site.log.note("took in the driveway #{road.id} to the street")
      taken = pts.select { |p| Geometry.contains?(poly, p) || Geometry.distance_to_edges(poly, p) <= ENTRANCE_REACH_M }
      access = street_access(taken, site.features)
      site.log.access_point(access) if access
      taken
    end

    def meets_public_road?(points, features)
      street = points.filter_map do |p|
        nearest_street_point(p, features)&.then { |q| Geometry.distance(p, q) }
      end
      street.any? { |d| d <= ENTRANCE_MAX_M }
    end

    # Where the part of a driveway taken in meets the street: the point on a
    # public road nearest it, or nil if that's further than ENTRANCE_MAX_M
    # (the driveway reaches the street elsewhere, beyond the premises).
    def street_access(points, features)
      pair = points.filter_map { |p| nearest_street_point(p, features)&.then { |q| [p, q] } }
                   .min_by { |p, q| Geometry.distance(p, q) }
      return nil unless pair && Geometry.distance(*pair) <= ENTRANCE_MAX_M

      pair.last
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
      log.note("parking #{lot.id} also touches building #{others.map(&:id).join(", ")}") if others.any?
      part
    end

    # Other buildings the lot touches (not ones joined to the site's own),
    # nearest first.
    def lot_neighbours(lot, features, target, opts)
      touching = neighbours(features, target, opts).select do |other|
        touches?(lot, other, opts) && !Geometry.overlap?(other.hull, target.hull)
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

        log.note("stopped 1 m short of building #{other.id}")
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
                                 "#{shared.size} shared parking lot(s)")
      poly
    end

    def lot_label(lot)
      lot.kind == "building" ? "#{lot.category || "small"} structure #{lot.id}" : "parking #{lot.id}"
    end
  end
end
