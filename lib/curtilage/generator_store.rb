# frozen_string_literal: true

module Curtilage
  # The store zone: the outline of the building the premises were made
  # from, for an "in the store" area inside the premises.
  module Generator
    STORE_MARGIN_M = 0.05

    module_function

    # The building's OSM footprint, simplified to max_store_vertices.
    # Footprints can be any shape (L, U, courtyards' outer edge); if
    # simplifying would make the outline cross itself, its convex outline is
    # used instead. It is then kept inside the premises by store_margin, so
    # the store zone always sits within them, even after rounding.
    def store_xy(target, premises, opts, log, features = nil)
      xy = Geometry.clean(Geometry.counter_clockwise(target.xy))
      if xy.size > opts[:max_store_vertices]
        simple = Geometry.simplify(xy, opts[:max_store_vertices])
        xy = Geometry.self_intersects?(simple) ? Geometry.simplify(target.hull, opts[:max_store_vertices]) : simple
      end
      unit = opts[:unit_m] && unit_xy(xy, target, features, opts, log)
      unit ? xy = unit : flag_unit(target, opts, log)
      inside = inside_premises(xy, premises, store_margin(opts[:precision]))
      unless inside
        log.note("left out the store zone: it doesn't fit inside the premises",
                 step: "trim_store", features: [target.id])
        return nil
      end
      if Geometry.area(inside) < Geometry.area(xy) - 1
        log.note("trimmed the store outline to fit inside the premises",
                 step: "trim_store", features: [target.id], area_before_m2: m2(xy), area_after_m2: m2(inside))
      end
      inside
    end

    # unit_m: for a building large enough to be shared, the slice unit_m
    # wide along its frontage (the side facing the nearest public road, else
    # its long side) centred on the pin, kept within the building. No data
    # source maps units, entrances or address points, so it's an estimate,
    # flagged unit_estimated; nil when the building isn't large or is about
    # one unit wide.
    def unit_xy(xy, target, features, opts, log)
      return nil unless target.area > opts[:large_building_note_m2]

      unit = unit_slice(xy, target, frontage_axis(target, features), opts[:unit_m])
      return nil unless unit

      log.flag(:unit_estimated, "the store zone is an estimated unit: #{opts[:unit_m]} m of the building's " \
                                "frontage round the pin (#{m2(unit)} of #{target.area.round} m2): check it",
               step: "estimate_unit", rule: "unit_m", features: [target.id], distance_m: opts[:unit_m],
               area_before_m2: m2(xy), area_after_m2: m2(unit))
      unit
    end

    # The part of xy width metres wide along the direction, centred on the
    # pin (0, 0) but kept within the building; nil if the building is under
    # 1.5 widths along it or the cut isn't a usable shape.
    def unit_slice(xy, target, along, width)
      ts = target.hull.map { |p| Geometry.dot(p, along) }
      return nil if ts.max - ts.min < 1.5 * width

      from = (-width / 2.0).clamp(ts.min, ts.max - width)
      unit = Geometry.clean(Geometry.clip_convex(xy, slice(along, from, from + width)))
      unit.size < 3 || Geometry.self_intersects?(unit) ? nil : unit
    end

    # The unit direction units line up along: the building's side facing
    # the nearest public road, else its long side.
    def frontage_axis(target, features)
      angle = target.rectangle[:angle]
      axes = [[Math.cos(angle), Math.sin(angle)], [-Math.sin(angle), Math.cos(angle)]]
      centre = Geometry.centroid(target.hull)
      street = features && nearest_street_point(centre, features)
      if street
        to_street = [street[0] - centre[0], street[1] - centre[1]]
        return axes.min_by { |a| Geometry.dot(a, to_street).abs }
      end
      axes.max_by { |a| target.hull.map { |p| Geometry.dot(p, a) }.minmax.then { |lo, hi| hi - lo } }
    end

    # The band between from and to metres along the unit direction along.
    def slice(along, from, upto)
      across = [-along[1], along[0]]
      far = 1e4
      [[from, -far], [upto, -far], [upto, far], [from, far]].map do |at, off|
        [(along[0] * at) + (across[0] * off), (along[1] * at) + (across[1] * off)]
      end
    end

    def flag_unit(target, opts, log)
      return unless target.area > opts[:large_building_note_m2]

      log.flag(:store_may_be_unit, "the store outline is the whole #{target.area.round} m2 building: " \
                                   "if the store is one unit of it, trim the outline to that unit",
               step: "check_store", rule: "large_building_note_m2", features: [target.id])
    end

    # The part of xy at least margin metres inside the premises. Convex
    # premises clip it; other shapes (entrances: :all) are built to hold the
    # building with room to spare, so the outline is kept whole if it fits
    # and clipped to their convex outline if that then fits, else nil.
    def inside_premises(xy, premises, margin)
      if Geometry.convex?(premises)
        inside = Geometry.clean(Geometry.clip_inside(xy, premises, margin))
        return inside.size >= 3 ? inside : nil
      end
      return xy if Geometry.ring_inside?(xy, premises, margin)

      hull = Geometry.counter_clockwise(Geometry.convex_hull(premises))
      clipped = Geometry.clean(Geometry.clip_inside(xy, hull, margin))
      clipped.size >= 3 && Geometry.ring_inside?(clipped, premises, margin) ? clipped : nil
    end

    # Rounding to precision decimal places moves each corner of both rings by
    # up to half a unit in each axis (a degree is longest along the equator),
    # so a store corner and a premises edge can close in by twice the
    # diagonal of that: keep at least that much apart (plus a centimetre),
    # and never less than STORE_MARGIN_M.
    def store_margin(precision)
      rounding = 0.5 * (10.0**-precision) * Geometry::METRES_PER_DEGREE_LNG_AT_EQUATOR
      [STORE_MARGIN_M, (2 * Math.sqrt(2) * rounding) + 0.01].max
    end
  end
end
