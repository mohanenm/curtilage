# frozen_string_literal: true

require "json"

module Curtilage
  # Sites where OpenStreetMap has no building near the pin, as a task list
  # for mappers (curtilage missing-buildings): a way to give back to OSM.
  # Points only, without your site ids unless asked: a list of where your
  # sites are can be private, so check before sharing or publishing it.
  module MissingBuildings
    # A machine-learned footprint this close to the pin is worth tracing.
    FOOTPRINT_REACH_M = 30
    TASK = "No building is mapped in OpenStreetMap at this point. If imagery shows one, trace it " \
           "(and tag it if you know what it is)."

    module_function

    # GeoJSON Point features for the results with no building found.
    # results need their map data (generate with keep_features: true) for
    # the footprint hint. with_ids: copy your site ids into properties.
    def features(results, ids, with_ids: false)
      results.zip(ids).filter_map do |result, id|
        next unless missing?(result)

        properties = { task: TASK, footprint_nearby: footprint_nearby?(result), source: "curtilage" }
        properties[:id] = id if with_ids
        { type: "Feature", geometry: { type: "Point", coordinates: result.pin }, properties: properties }
      end
    end

    # No building found, from map data that covered the pin (not a site
    # with no data at all, or one that failed).
    def missing?(result)
      result.building.nil? && !result.flags.intersect?(%i[no_data error partial_data]) &&
        result.steps.to_a.any? { |s| s[:step] == "find_building" }
    end

    def footprint_nearby?(result)
      features = result.features
      return false unless features

      features.ml_buildings.any? do |b|
        Geometry.contains?(b.xy, [0.0, 0.0]) || Geometry.distance_to_edges(b.xy, [0.0, 0.0]) <= FOOTPRINT_REACH_M
      end
    end

    # A FeatureCollection, or for MapRoulette's line-by-line upload one
    # FeatureCollection a line (one task each), each line starting with the
    # record separator RFC 7464 uses.
    def write(features, maproulette: false)
      return "#{JSON.pretty_generate(type: "FeatureCollection", features: features)}\n" unless maproulette

      features.map { |f| "\u001e#{JSON.generate(type: "FeatureCollection", features: [f])}\n" }.join
    end
  end
end
