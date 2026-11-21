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
    # used instead. It is then kept STORE_MARGIN_M inside the premises, so
    # the store zone always sits within them, even after rounding.
    def store_xy(target, premises, opts, log)
      xy = Geometry.clean(Geometry.counter_clockwise(target.xy))
      if xy.size > opts[:max_store_vertices]
        simple = Geometry.simplify(xy, opts[:max_store_vertices])
        xy = Geometry.self_intersects?(simple) ? Geometry.simplify(target.hull, opts[:max_store_vertices]) : simple
      end
      if target.area > opts[:large_building_note_m2]
        log.flag(:store_may_be_unit, "the store outline is the whole #{target.area.round} m2 building: " \
                                     "if the store is one unit of it, trim the outline to that unit")
      end
      inside = Geometry.clean(Geometry.clip_inside(xy, premises, STORE_MARGIN_M))
      log.note("trimmed the store outline to fit inside the premises") if Geometry.area(inside) < Geometry.area(xy) - 1
      inside
    end
  end
end
