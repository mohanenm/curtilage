# frozen_string_literal: true

module Curtilage
  # Property lines the caller supplies ("parcel" features, or parcels: on
  # generate_many). The premises don't cross the parcel the building sits
  # in, unless the site's own mapped parking clearly runs past it: then that
  # parking stays in and the result is flagged beyond_parcel. Parcels are
  # never fetched from anywhere; their licence is the caller's to check.
  module Generator
    BEYOND_PARCEL_M2 = 100 # claimed parking past the parcel at least this big stays in

    module_function

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
