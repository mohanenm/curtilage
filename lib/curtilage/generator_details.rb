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

    def details(target, premises, features, pin, log, precision: 7)
      parking = parking_area(premises, features)
      entrances = entrances(log, pin, precision)
      {
        building: building_info(target, pin, precision),
        parking_area_m2: parking.round,
        parking_spaces_estimate: (parking / M2_PER_PARKING_SPACE).floor,
        frontage_m: frontage(premises, features).round,
        access_points: entrances.map { |e| e[:point] },
        entrances: entrances,
      }
    end

    # Where vehicles enter from the street: one per driveway mouth (those
    # within ACCESS_MERGE_M are one), with the street it opens onto.
    def entrances(log, pin, precision)
      distinct(log.access || []).map do |a|
        street = a[:street]
        { point: Geometry.lnglat([a[:xy]], pin, precision).first, street: street.name, street_class: street.highway,
          street_id: street.id, driveway: a[:driveway] }
      end
    end

    # Driveways mapped as several pieces meet the street at nearly the same
    # spot: count it once.
    def distinct(access, within = ACCESS_MERGE_M)
      access.each_with_object([]) do |a, out|
        out << a unless out.any? { |b| Geometry.distance(a[:xy], b[:xy]) < within }
      end
    end

    def building_info(target, pin, precision)
      return nil unless target

      outline = Geometry.lnglat(target.xy, pin, precision)
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
      roads = features.public_roads
      premises.each_index.sum do |i|
        a = premises[i]
        b = premises[(i + 1) % premises.size]
        along_road?(Geometry.lerp(a, b, 0.5), roads) ? Geometry.distance(a, b) : 0
      end
    end

    def along_road?(point, roads)
      roads.any? do |road|
        reach = ROAD_HALF_WIDTH_M.fetch(road.highway, ROAD_HALF_WIDTH_M["link"]) + FRONTAGE_REACH_M
        road.xy.each_cons(2).any? { |p, q| Geometry.segment_distance(point, p, q) <= reach }
      end
    end
  end
end
