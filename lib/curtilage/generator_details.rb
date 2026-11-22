# frozen_string_literal: true

module Curtilage
  # Facts about the site that fall out of generation: the building, how
  # much mapped parking the premises hold, street frontage and where
  # driveways meet the street. Rough by nature (from open map data); handy
  # for delivery, site analysis and the like.
  module Generator
    # Typical area per parking space, aisles included.
    M2_PER_PARKING_SPACE = 25
    # A premises edge counts as frontage when its middle is this much beyond
    # the road's half width from the centreline (the trims stop short of it).
    FRONTAGE_REACH_M = 3
    # Access points closer than this are one entrance.
    ACCESS_MERGE_M = 10

    module_function

    def details(target, premises, features, pin, log)
      parking = parking_area(premises, features)
      {
        building: building_info(target, pin),
        parking_area_m2: parking.round,
        parking_spaces_estimate: (parking / M2_PER_PARKING_SPACE).floor,
        frontage_m: frontage(premises, features).round,
        access_points: to_lnglat(distinct(log.access || []), pin),
      }
    end

    # Driveways mapped as several pieces meet the street at nearly the same
    # spot: count it once.
    def distinct(points, within = ACCESS_MERGE_M)
      points.each_with_object([]) do |p, out|
        out << p unless out.any? { |q| Math.hypot(p[0] - q[0], p[1] - q[1]) < within }
      end
    end

    def building_info(target, pin)
      return nil unless target

      outline = to_lnglat(target.xy, pin)
      { id: target.id, name: target.name, type: target.category, area_m2: target.area.round,
        footprint: outline + [outline.first] }
    end

    # Mapped parking inside the premises.
    def parking_area(premises, features)
      area = Geometry.bounds(premises)
      features.parking.sum do |lot|
        next 0 unless Geometry.bounds_near?(lot.bounds, area)

        part = Geometry.clip_convex(lot.xy, premises)
        part.size >= 3 ? Geometry.area(part) : 0
      end
    end

    # Length of premises edges running along a public road.
    def frontage(premises, features)
      roads = features.roads.select { |r| PUBLIC_HIGHWAYS.include?(r.highway) }
      premises.each_index.sum do |i|
        a = premises[i]
        b = premises[(i + 1) % premises.size]
        along_road?(Geometry.lerp(a, b, 0.5), roads) ? Math.hypot(b[0] - a[0], b[1] - a[1]) : 0
      end
    end

    def along_road?(point, roads)
      roads.any? do |road|
        reach = ROAD_HALF_WIDTH_M.fetch(road.highway, ROAD_HALF_WIDTH_M["link"]) + FRONTAGE_REACH_M
        road.xy.each_cons(2).any? { |p, q| Geometry.segment_distance(point, p, q) <= reach }
      end
    end

    def to_lnglat(xy, pin)
      Geometry.unproject(xy, pin).map { |lng, lat| [lng.round(7), lat.round(7)] }
    end
  end
end
