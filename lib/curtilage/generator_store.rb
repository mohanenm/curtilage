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
    def store_xy(target, premises, opts, log)
      xy = Geometry.clean(Geometry.counter_clockwise(target.xy))
      if xy.size > opts[:max_store_vertices]
        simple = Geometry.simplify(xy, opts[:max_store_vertices])
        xy = Geometry.self_intersects?(simple) ? Geometry.simplify(target.hull, opts[:max_store_vertices]) : simple
      end
      flag_unit(target, opts, log)
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
