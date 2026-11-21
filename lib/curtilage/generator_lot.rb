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
    # (shopping-centre) lot: splitting it between them leaves slivers, and it
    # isn't this site's alone, so it's left out and flagged.
    #
    # Parking garages, carports and canopies next to the building count as
    # lot too (LOT_TYPES).
    def own_parking(features, target, opts, log)
      structures = features.buildings.select do |b|
        !b.equal?(target) && (LOT_TYPES.include?(b.category) || b.area < opts[:small_building_m2])
      end
      (features.parking + structures).select do |lot|
        next false unless Geometry.contains?(lot.xy, [0.0, 0.0]) || touches?(lot, target, opts)

        others = sharers(lot, features, target, opts)
        if others >= opts[:shared_lot_buildings]
          lot.instance_variable_set(:@shared, true)
          log.note("parking #{lot.id} (#{lot.area.round} m2) is shared with #{others} other buildings: " \
                   "claimed only within #{opts[:grow_m]} m of the building")
          next true
        end
        log.note("#{lot_label(lot)} (#{lot.area.round} m2) touches the building, so it's part of the lot")
        true
      end
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
    # A shared (shopping-centre) lot is claimed only near the building, and
    # the driveways linking the claimed lot to a public road are taken in.
    def add_parking(poly, lots, site)
      near = fence(site, site.opts[:grow_m])
      far = fence(site, site.opts[:parking_max_extent_m])
      parts = lots.map do |lot|
        reach = lot.instance_variable_get(:@shared) ? near : far
        share_lot(Geometry.clip_convex(lot.xy, reach), lot, site)
      end
      grown = Geometry.counter_clockwise(Geometry.convex_hull(poly + parts.select { |p| p.size >= 3 }.flatten(1)))
      grown = add_entrances(grown, far, site)
      keep_off_neighbours(grown, site.features, site.target, site.opts, site.log)
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
        pts = road.xy.each_cons(2).flat_map { |a, b| samples(a, b) }.select { |p| Geometry.contains?(fence, p) }
        next [] unless pts.any? { |p| Geometry.contains?(poly, p) } && meets_public_road?(pts, site.features)

        pts = pts.select { |p| Geometry.contains?(poly, p) || Geometry.distance_to_edges(poly, p) <= ENTRANCE_REACH_M }

        site.log.note("took in the driveway #{road.id} to the street")
        pts
      end
      return poly if points.empty?

      Geometry.counter_clockwise(Geometry.convex_hull(poly + points))
    end

    def meets_public_road?(points, features)
      street = points.filter_map do |p|
        nearest_street_point(p, features)&.then do |q|
          Math.hypot(q[0] - p[0], q[1] - p[1])
        end
      end
      street.any? { |d| d <= ENTRANCE_MAX_M }
    end

    # A lot the site shares with one or two other buildings is still the
    # site's (three or more is a shopping-centre lot, left out earlier): it is
    # claimed whole, and keep_off_neighbours stays clear of their walls.
    # Homes are the exception: a lot touching one is split halfway with it,
    # so the claim stops short of the yard.
    def share_lot(part, lot, site)
      features, target, opts, log = site.to_a
      others = neighbours(features, target, opts).select do |other|
        touches?(lot, other, opts) && !Geometry.overlap?(other.hull, target.hull)
      end
      others.each do |other|
        next unless home?(other, features, opts) && part.size >= 3

        part = split_from_neighbour(part, target.hull, other.hull, target.rectangle[:angle])
        log.note("parking #{lot.id} also touches home #{other.id}: split halfway")
      end
      log.note("parking #{lot.id} also touches building #{others.map(&:id).join(", ")}") if others.any?
      part
    end

    # Stops 1 m short of any neighbouring building the lot reached.
    def keep_off_neighbours(poly, features, target, opts, log)
      area = Geometry.bounds(poly)
      neighbours(features, target, opts).each do |other|
        next unless Geometry.bounds_near?(area, other.bounds)
        next if Geometry.overlap?(other.hull, target.hull) || !Geometry.overlap?(other.hull, poly)

        trimmed = split_from_neighbour(poly, target.hull, other.hull, target.rectangle[:angle],
                                       stop: ->(near, far) { [far - 1, near].max })
        next if trimmed.size < 3

        log.note("stopped 1 m short of building #{other.id}")
        poly = trimmed
      end
      poly
    end

    def lot_label(lot)
      lot.kind == "building" ? "#{lot.category || "small"} structure #{lot.id}" : "parking #{lot.id}"
    end
  end
end
