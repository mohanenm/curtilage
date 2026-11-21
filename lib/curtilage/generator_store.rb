# frozen_string_literal: true

module Curtilage
  # The store zone: the outline of the building the premises were made
  # from, for an "in the store" area inside the premises.
  module Generator
    module_function

    # The building's OSM footprint as a closed [lng, lat] ring, simplified
    # to max_store_vertices. Footprints can be any shape (L, U, courtyards'
    # outer edge); if simplifying would make the outline cross itself, its
    # convex outline is used instead.
    def store_ring(target, pin, opts, log)
      xy = Geometry.clean(Geometry.counter_clockwise(target.xy))
      if xy.size > opts[:max_store_vertices]
        simple = Geometry.simplify(xy, opts[:max_store_vertices])
        xy = Geometry.self_intersects?(simple) ? Geometry.simplify(target.hull, opts[:max_store_vertices]) : simple
      end
      if target.area > opts[:large_building_note_m2]
        log.flag(:store_may_be_unit, "the store outline is the whole #{target.area.round} m2 building: " \
                                     "if the store is one unit of it, trim the outline to that unit")
      end
      ring = Geometry.unproject(xy, pin).map { |lng, lat| [lng.round(7), lat.round(7)] }
      ring << ring.first
    end
  end
end
