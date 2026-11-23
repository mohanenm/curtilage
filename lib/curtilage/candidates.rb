# frozen_string_literal: true

module Curtilage
  # Other premises a site could have, for when the result is ambiguous
  # (generate's candidates: N): a reviewer or a downstream system picks.
  # Each is a full Result with its own confidence, flags and steps.
  module Candidates
    # Below this confidence the building rectangle is offered too.
    LOW_CONFIDENCE = 0.7
    MAX = 5

    module_function

    # Up to count valid alternatives to result, unlike it and each other,
    # most confident first:
    # - another building within building_max_distance_m of the pin (the pin
    #   may be on the wrong one), with the pin moved onto it;
    # - on a shared lot, the whole shopping centre (scope: :centre);
    # - when confidence is low, the building rectangle (method: :building).
    def for(result, pin, features, options, count)
      unless count.is_a?(Integer) && count.between?(1, MAX)
        raise ArgumentError, "candidates must be a whole number from 1 to #{MAX}: #{count.inspect}"
      end

      features = Features.new(pin, features) unless features.is_a?(Features)
      found = other_buildings(result, features, options) + other_shapes(result, pin, features, options)
      found.select(&:ok?).reject { |c| c.ring == result.ring }.uniq(&:ring)
           .sort_by { |c| -c.confidence }.first(count)
    end

    def other_buildings(result, features, options)
      opts = Generator.checked_options(Curtilage.send(:preset_options, options[:preset])
                                                .merge(options.except(:preset, :method)))
      own = Generator.choose_buildings(features, opts[:buildings])
      reach = own.buildings.filter_map do |b|
        distance = Geometry.distance_to_edges(b.xy, Generator::ORIGIN)
        [distance, b] if b.id != result.building && distance <= opts[:building_max_distance_m] &&
                         b.area >= opts[:small_building_m2]
      end
      reach.sort_by { |d, b| [d, b.id.to_s] }.first(MAX).map { |d, b| on_building(b, d, features, result, options) }
    end

    def on_building(building, distance, features, result, options)
      moved = features.moved_to(Generator.inside_point(building))
      Curtilage.generate(moved.pin, moved, **options).tap do |c|
        c.flags << :pin_moved unless c.flags.include?(:pin_moved)
        c.pin_quality = (result.pin_quality || {}).merge(moved_from: result.pin)
        c.prepend_step("candidate: building #{building.id}, #{distance.round} m from the pin, instead",
                       step: "candidate", features: [building.id], distance_m: distance.round(1))
      end
    end

    def other_shapes(result, pin, features, options)
      shared = result.steps.to_a.any? { |s| s[:rule] == "shared_lot_buildings" }
      list = []
      list << [{ scope: :centre }, "the whole shopping centre"] if shared && options[:scope] != :centre
      if result.method_name == :grow_trim && result.confidence < LOW_CONFIDENCE
        list << [{ method: :building }, "the building rectangle"]
      end
      list.map do |change, words|
        Curtilage.generate(pin, features, **options, **change).tap do |c|
          c.prepend_step("candidate: #{words}", step: "candidate", rule: change.keys.first.to_s)
        end
      end
    end
  end
end
