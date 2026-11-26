# frozen_string_literal: true

module Curtilage
  # How far to trust a result, 0 to 1, from what's known about how it was
  # made: rule-based, no learning. Each factor that isn't met takes its
  # weight off 1 (never below 0), so the score always comes with the reasons
  # behind it. Flags say what to look at; confidence orders sites for review.
  #
  # The weights are judgement, not fitted, and uncalibrated: on the public
  # benchmark the score doesn't yet order sites by error (docs/reference.md,
  # Confidence). Data age isn't a factor, as it would make the same inputs score differently over time.
  module Confidence
    # name => [weight, what it means when met]
    FACTORS = {
      valid: [1.0, "The premises passed validation."],
      main_method: [0.30, "Made by the main method (no fallback to the building rectangle)."],
      building_under_pin: [0.20, "The pin was given on the building used (not near it, nor moved onto it)."],
      full_data: [0.20, "Map data covers the whole area around the pin."],
      osm_building: [0.10, "The building is from OpenStreetMap, not a machine-learned footprint."],
      single_building_store: [0.10, "The building is small enough to be one store, not several tenants."],
      plausible_building: [0.15, "The building is big enough to be a store, not a kiosk or canopy."],
      mapped_parking: [0.15, "Mapped parking is inside the premises."],
      road_frontage: [0.15, "At least one side of the premises runs along a public road."],
      no_homes_next_door: [0.10, "No home borders the lot."],
      own_lot: [0.10, "The lot isn't split with other buildings (where a shared lot divides isn't in the map)."],
      no_warnings: [0.05, "Validation raised no warnings (size, shape and position look typical)."],
      steady_pin: [0.10, "A pin moved a few metres would pick the same building (no pin_quality warnings)."],
    }.freeze

    # With shared_checks: true, a store that may be one unit and a shared lot
    # count for more: they are where results are least sure.
    SHARED_WEIGHTS = { single_building_store: 0.25, own_lot: 0.20 }.freeze

    module_function

    # [score, factors]: the score rounded to 2 places, and every factor as
    # { name:, met:, weight: }.
    def assess(result)
      return [result.ok? ? 1.0 : 0.0, [{ name: :valid, met: result.ok?, weight: 1.0 }]] if result.method_name == :manual

      shared = result.provenance&.dig(:options, :shared_checks)
      factors = met(result).map do |name, ok|
        { name: name, met: ok, weight: (shared && SHARED_WEIGHTS[name]) || FACTORS.fetch(name)[0] }
      end
      lost = factors.reject { |f| f[:met] }.sum { |f| f[:weight] }
      [[1.0 - lost, 0.0].max.round(2), factors]
    end

    # With shared_checks, store_may_be_unit alone says it (it leaves out
    # single-occupant buildings that large_building flags by size).
    def single_store?(result)
      return false if result.flags.include?(:store_may_be_unit)

      result.provenance&.dig(:options, :shared_checks) || !result.flags.include?(:large_building)
    end

    def steady_pin?(result) = result.pin_quality.to_h[:warnings].nil?

    def met(result)
      flags = result.flags
      details = result.details || {}
      {
        valid: result.ok?, main_method: !flags.include?(:fallback),
        building_under_pin: !flags.intersect?(%i[building_not_under_pin pin_moved]),
        full_data: !flags.include?(:partial_data),
        osm_building: !flags.include?(:ml_footprint),
        single_building_store: single_store?(result),
        plausible_building: !flags.include?(:small_building),
        mapped_parking: details[:parking_area_m2].to_f.positive?, road_frontage: details[:frontage_m].to_f.positive?,
        no_homes_next_door: !flags.include?(:near_houses), own_lot: !flags.include?(:shared_lot),
        no_warnings: result.validation.warnings.empty?, steady_pin: steady_pin?(result)
      }
    end
  end
end
