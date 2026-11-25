# frozen_string_literal: true

module Curtilage
  # Property lines the caller supplies ("parcel" features, or parcels: on
  # generate_many). The premises don't cross the parcel the building sits
  # in, unless the site's own mapped parking clearly runs past it: then that
  # parking stays in and the result is flagged beyond_parcel. Parcels are
  # never fetched from anywhere; their licence is the caller's to check.
  #
  # parcel_mode: says how else the parcel is used. :clip (the default) only
  # clips, as above. :grow instead adds the mapped parking and paved access
  # (service roads) inside the site's parcels to the premises, without
  # clipping them; :start begins from
  # the site's parcels instead of the grown building rectangle and lets the
  # usual rules trim them. Both use every parcel holding a quarter of the
  # building (a building on several parcels) and, joined to those, parcels
  # mostly covered by the site's own parking (a lot split over parcels).
  # A parcel holding other businesses' buildings (a shopping centre) is only
  # a limit: :grow and :start then clip as :clip does (flag shared_parcel).
  module Generator
    BEYOND_PARCEL_M2 = 100 # claimed parking past the parcel at least this big stays in
    PARCEL_MODES = %i[clip grow start].freeze
    PARCEL_BUILDING_SHARE = 0.25 # a parcel holding this share of the building is one of the site's
    PARCEL_LOT_SHARE = 0.3       # ... and so is a parcel joined to them this much covered by its own parking
    SERVICE_ROAD_HALF_M = 3      # :grow: paved access is this much either side of a service road
    SHARED_PARCEL_OTHERS = 2     # a parcel also holding this many other businesses' buildings is a centre's

    module_function

    # :grow and :start: the site's parcels as rings, or nil when there are
    # none or they're shared with other businesses (flagged).
    def site_parcels(site, lots = [])
      features = site.features
      target = site.target
      parts = features.parcels.select do |p|
        Geometry.overlap_area(target.hull, p.xy) >= target.area * PARCEL_BUILDING_SHARE
      end
      return nil if parts.empty?

      parts += split_parcels(features.parcels - parts, parts, lots)
      others = parcel_businesses(parts, site)
      return parts.map(&:xy) if others.size < SHARED_PARCEL_OTHERS

      text = "the building's parcel also holds #{others.size} other building(s) (a centre or shared lot): " \
             "used only as a limit"
      site.log.flag(:shared_parcel, text, step: "site_parcels", rule: "parcel_mode", features: parts.map(&:id))
      nil
    end

    def split_parcels(candidates, parts, lots)
      parking = lots.select { |lot| lot.kind == "parking" }
      candidates.select do |p|
        parts.any? { |q| Geometry.closest_points(p.xy, q.xy).first <= 1 } &&
          parking.sum { |lot| Geometry.overlap_area(lot.xy, p.xy) } >= Geometry.area(p.xy) * PARCEL_LOT_SHARE
      end
    end

    # Other businesses' buildings mostly inside the parcels (not homes,
    # sheds or canopies).
    def parcel_businesses(parts, site)
      neighbours(site.features, site.target, site.opts).select do |b|
        next false if LOT_TYPES.include?(b.category) || home?(b, site.features, site.opts)

        parts.sum { |p| Geometry.overlap_area(b.hull, p.xy) } >= b.area / 2
      end
    end

    # :start: the site's parcels' outline (with the building), when it's a
    # usable size; nil otherwise.
    def parcel_start(features, target, opts, log)
      rings = site_parcels(Site.new(features, target, opts, log)) or return nil
      start = Geometry.counter_clockwise(Geometry.convex_hull(rings.flatten(1) + target.hull))
      return nil if Geometry.area(start) > opts[:centre_max_m2]

      log.note("started from the building's parcel (#{Geometry.area(start).round} m2) instead of a grown rectangle",
               step: "grow", rule: "parcel_mode", area_after_m2: m2(start))
      start
    end

    # :grow and :start: mapped parking mostly inside the site's parcels, which
    # is the site's even where the rules didn't claim it (so it isn't cut out
    # as another business's lot).
    def parcel_lots(features, target, opts)
      return [] unless %i[grow start].include?(opts[:parcel_mode]) && features.parcels.any?

      rings = site_parcels(Site.new(features, target, opts, Log.new([], []))) or return []
      features.parking.select { |lot| rings.sum { |r| Geometry.overlap_area(lot.xy, r) } >= Geometry.area(lot.xy) / 2 }
    end

    # Mapped parking and service roads (with SERVICE_ROAD_HALF_M either side).
    def paint_paved(grid, features)
      features.parking.each { |lot| grid.paint(lot.xy) }
      features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }.each do |road|
        road.xy.each_cons(2) { |a, b| grid.paint(Geometry.round_buffer([a, b], SERVICE_ROAD_HALF_M, 8)) }
      end
      grid
    end

    # The building rectangle grown by grow_m, or (parcel_mode: :start) the
    # building's parcel.
    def start_shape(features, target, opts, log)
      start = parcel_start(features, target, opts, log) if opts[:parcel_mode] == :start && features.parcels.any?
      return start if start

      poly = grown(target, opts[:grow_m], opts)
      log.note("grew the building rectangle by #{opts[:grow_m]} m", step: "grow", rule: "grow_m", features: [target.id],
                                                                    distance_m: opts[:grow_m], area_after_m2: m2(poly))
      poly
    end

    # :grow: the premises plus the mapped parking and paved access inside
    # the site's parcels (the premises themselves aren't clipped); nil when
    # that can't be done.
    def grow_in_parcels(poly, lots, site)
      rings = site_parcels(site, lots) or return nil
      extent = Geometry.bounds(poly + rings.flatten(1))
      grid = paint_paved(Grid.new(extent, corridor_cell(extent), pad: SERVICE_ROAD_HALF_M).paint(poly), site.features)
      grid.close(SERVICE_ROAD_HALF_M) # across planting strips between the lots
      grid.keep_inside(rings).paint(poly) # the rules' own result stays whole: this only adds
      [Geometry.round_buffer(site.target.hull, grid.cell + 0.2), pin_square(site.opts)].each { |xy| grid.paint(xy) }
      xy = finish_grid(grid) or return nil
      site.log.note("took in the mapped parking and service roads inside the building's parcel",
                    step: "clip_parcel", rule: "parcel_mode", area_before_m2: m2(poly), area_after_m2: m2(xy))
      xy
    end

    # The premises clipped to the building's parcel, or unchanged when no
    # parcel holds most of the building or the premises are inside it.
    def clip_to_parcel(poly, lots, site)
      parcel = building_parcel(site.features, site.target)
      return poly if parcel.nil? || Geometry.ring_inside?(poly, parcel.xy)

      parking = lots.select { |lot| lot.kind == "parking" }.map(&:xy)
      own = parcel_grid(poly, [parcel.xy], site)
      wider = parcel_grid(poly, [parcel.xy] + parking, site)
      beyond = wider.area - own.area
      grid = beyond >= BEYOND_PARCEL_M2 ? wider : own
      xy = finish_grid(grid)
      return poly unless xy

      note_parcel(site.log, parcel, beyond, [poly, xy])
      xy
    end

    # The parcel holding at least half the building (the most of it).
    def building_parcel(features, target)
      best = features.parcels.map { |p| [Geometry.overlap_area(target.hull, p.xy), p] }.max_by(&:first)
      best && best[0] >= target.area / 2 ? best[1] : nil
    end

    def parcel_grid(poly, keep, site)
      extent = Geometry.bounds(poly)
      Grid.new(extent, corridor_cell(extent)).paint(poly).keep_inside(keep).tap do |grid|
        [Geometry.round_buffer(site.target.hull, grid.cell + 0.2), pin_square(site.opts)].each { |xy| grid.paint(xy) }
      end
    end

    def finish_grid(grid)
      return nil unless grid.keep_part?([0.0, 0.0])

      Geometry.counter_clockwise(Geometry.douglas_peucker(grid.outline, grid.cell))
    end

    def note_parcel(log, parcel, beyond, polys)
      fields = { step: "clip_parcel", rule: "parcels", features: [parcel.id],
                 area_before_m2: m2(polys[0]), area_after_m2: m2(polys[1]) }
      if beyond >= BEYOND_PARCEL_M2
        log.flag(:beyond_parcel, "kept the site's parking where it runs #{beyond.round} m2 past the building's " \
                                 "parcel: check the property line", **fields)
      else
        log.note("clipped the premises to the building's parcel #{parcel.id}", **fields)
      end
    end
  end
end
