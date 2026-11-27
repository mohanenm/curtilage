# frozen_string_literal: true

module Curtilage
  # The pin: how good it is (geocoders often drop pins on the street or the
  # wrong building) and, if asked (snap_m:), moving it onto the nearest
  # building. Features are in metres around the pin, which is [0, 0].
  module Generator
    ORIGIN = [0.0, 0.0].freeze
    DEFAULT_SNAP_M = 30
    # A snapped pin goes this far inside the building's edge.
    SNAP_INSET_M = 1

    PIN_MARGIN_M = 3 # a pin moved this far could pick another building, or none

    module_function

    # { quality:, building_m: } for the pin as given: on_building, on_road
    # (within half a public road's width of its centreline), near_building
    # (a building within building_max_distance_m) or far; building_m is the
    # distance to the nearest building's edge (0 on one, nil with none).
    def pin_quality(features, opts)
      warnings = pin_warnings(features, opts)
      extra = warnings.empty? ? {} : { warnings: warnings }
      return { quality: "on_building", building_m: 0, **extra } if on_building?(features)

      nearest = features.buildings.map { |b| Geometry.distance_to_edges(b.xy, ORIGIN) }.min
      quality = if features.public_roads.any? { |r| road_distance(r) <= road_offset(r, opts) } then "on_road"
                elsif nearest && nearest <= opts[:building_max_distance_m] then "near_building"
                else "far"
                end
      { quality: quality, building_m: nearest&.round(1), **extra }
    end

    # Where a pin moved a few metres (GPS and geocoders are off by more)
    # could give a different result: a second building nearly as close as
    # the nearest (second_building), or the nearest at about the reach limit,
    # either side of it (reach_limit). Kiosks and canopies don't count.
    def pin_warnings(features, opts)
      real = features.buildings.reject { |b| b.area < opts[:small_building_m2] }
      d = real.map { |b| Geometry.contains?(b.xy, ORIGIN) ? 0.0 : Geometry.distance_to_edges(b.xy, ORIGIN) }.sort
      warnings = []
      warnings << "second_building" if d.size >= 2 && d[1] - d[0] <= PIN_MARGIN_M
      near_limit = d.any? && d[0].positive? && (opts[:building_max_distance_m] - d[0]).abs <= PIN_MARGIN_M
      warnings << "reach_limit" if near_limit
      warnings
    end

    def on_building?(features) = features.buildings.any? { |b| Geometry.contains?(b.xy, ORIGIN) }

    def road_distance(road)
      road.xy.each_cons(2).map { |a, b| Geometry.segment_distance(ORIGIN, a, b) }.min || Float::INFINITY
    end

    # [features around the moved pin, the pin as given], or [features, nil]
    # when the pin is on a building or none is within snap_m.
    def snap_pin(features, opts, log)
      return [features, nil] if on_building?(features)

      _, target = nearest_in_reach(features, opts, opts[:snap_m])
      return [features, nil] unless target

      point = inside_point(target)
      moved = Geometry.distance(point, ORIGIN)
      log.flag(:pin_moved, "moved the pin #{moved.round} m onto building #{target.id}: it wasn't on a building",
               step: "snap_pin", rule: "snap_m", features: [target.id], distance_m: moved.round(1))
      [features.moved_to(point), features.pin]
    end

    # [distance, building] for the nearest building within reach, preferring
    # real buildings to kiosks and canopies; nil if none.
    def nearest_in_reach(features, opts, reach)
      in_reach = features.buildings.map { |b| [Geometry.distance_to_edges(b.xy, ORIGIN), b] }
                         .select { |d, _| d <= reach }
      real = in_reach.reject { |_, b| b.area < opts[:small_building_m2] }
      (real.empty? ? in_reach : real).min_by(&:first)
    end

    # The building's edge point nearest the pin, carried SNAP_INSET_M on
    # inside; its centroid if that isn't inside (an odd shape).
    def inside_point(building)
      ring = building.xy + [building.xy.first]
      edge = ring.each_cons(2).map { |a, b| Geometry.closest_point_on_segment(ORIGIN, a, b) }
                 .min_by { |p| Geometry.distance(p, ORIGIN) }
      length = Geometry.distance(edge, ORIGIN)
      inset = edge.map { |v| v + (v / length * SNAP_INSET_M) }
      return inset if Geometry.contains?(building.xy, inset)

      centre = Geometry.centroid(building.xy)
      Geometry.contains?(building.xy, centre) ? centre : edge
    end
  end
end
