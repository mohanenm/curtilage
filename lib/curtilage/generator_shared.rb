# frozen_string_literal: true

module Curtilage
  # shared_checks: true (experimental, off by default): large and shared
  # buildings marked as the estimates they are. The premises don't change;
  # the flags, confidence and explanation do:
  # - store_may_be_unit for a building big enough to hold several stores,
  #   unless its type is one that normally has one occupant (a hotel, a
  #   school), or for one joined to other buildings (a row of shops);
  # - shared_lot also for a claimed lot that touches two other buildings
  #   (below shared_lot_buildings, so it is claimed whole);
  # - takes_in_building for premises holding another building's centre;
  # - confidence counts those two more (Confidence::SHARED_WEIGHTS);
  # - the explanation starts by saying the result is an estimate, and why.
  module Generator
    SINGLE_USE_TYPES = %w[hotel motel school college university kindergarten hospital church cathedral chapel
                          mosque synagogue temple civic public government townhall fire_station police library
                          museum supermarket warehouse stadium train_station transportation post_office].freeze
    ATTACHED_M = 1          # another building this close shares a wall
    SHARED_CHECK_OTHERS = 2 # a claimed lot touching this many other buildings may be shared

    module_function

    # Why the store may be one unit of its building (empty if no reason).
    def unit_reasons(target, features, opts)
      reasons = []
      if target.area > opts[:large_building_note_m2] && !SINGLE_USE_TYPES.include?(target.category)
        reasons << "the building is #{target.area.round} m2, big enough for several stores"
      end
      joined = attached(target, features, opts)
      reasons << "it is joined to #{joined.size} other building(s), as in a row of shops" if joined.any?
      reasons
    end

    def attached(target, features, opts)
      return [] unless features

      neighbours(features, target, opts).select do |b|
        !LOT_TYPES.include?(b.category) && !home?(b, features, opts) &&
          Geometry.closest_points(target.xy, b.xy).first <= ATTACHED_M
      end
    end

    def flag_shared_unit(target, features, opts, log)
      reasons = unit_reasons(target, features, opts)
      return if reasons.empty?

      log.flag(:store_may_be_unit, "the store outline is the whole building: #{reasons.join("; ")}; if the store " \
                                   "is one unit of it, trim the outline to that unit",
               step: "check_store", rule: "shared_checks", features: [target.id])
    end

    # After the premises are drawn: the buildings they take in, then the
    # estimate note.
    def check_shared(result, shape, opts, log)
      premises, target, features = shape
      flag_taken_buildings(premises, target, features, opts, log)
      note_estimate(result)
    end

    # Other buildings the premises take in (their centre inside them), not
    # canopies or car parks: often another business's. A whole centre takes
    # them in on purpose.
    def flag_taken_buildings(premises, target, features, opts, log)
      return if target.nil? || log.steps.any? { |s| s[:step] == "whole_centre" }

      taken = neighbours(features, target, opts).select do |b|
        !LOT_TYPES.include?(b.category) && Geometry.contains?(premises, Geometry.centroid(b.hull))
      end
      return if taken.empty?

      log.flag(:takes_in_building, "the premises take in #{taken.size} other building(s) " \
                                   "(#{taken.map { |b| "#{b.id}, #{b.area.round} m2" }.join("; ")}): if one is " \
                                   "another business's, trim the premises off it",
               step: "check_premises", rule: "shared_checks", features: taken.map(&:id))
    end

    # The first line of the explanation, when the result is an estimate.
    def note_estimate(result)
      why = []
      why << "the store may be one unit of a bigger building" if result.flags.include?(:store_may_be_unit)
      why << "the lot is shared with other buildings, and where it divides isn't in the map" \
        if result.flags.include?(:shared_lot)
      why << "the premises take in another building" if result.flags.include?(:takes_in_building)
      return if why.empty?

      text = "Estimate: #{why.join(", and ")}. The premises are the whole building and its share of the lot " \
             "as the rules see it; check them on imagery."
      result.explanation.unshift(text)
      result.steps.unshift({ step: "estimate", text: text, rule: "shared_checks" })
    end
  end
end
