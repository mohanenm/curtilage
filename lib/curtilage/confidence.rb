# frozen_string_literal: true

module Curtilage
  # How far to trust a result, 0 to 1, from what's known about how it was
  # made: rule-based, no learning. Each factor that isn't met takes its
  # weight off 1 (never below 0), so the score always comes with the reasons
  # behind it. Flags say what to look at; confidence orders sites for review.
  #
  # The weights are judgement, set before measuring: to be calibrated on the
  # public benchmark once its reference polygons exist. Data age isn't a
  # factor, as it would make the same inputs score differently over time.
  module Confidence
    # name => [weight, what it means when met]
    FACTORS = {
      valid: [1.0, "The premises passed validation."],
      main_method: [0.30, "Made by the main method (no fallback to the building rectangle)."],
      building_under_pin: [0.20, "The pin is on the building used."],
      full_data: [0.20, "Map data covers the whole area around the pin."],
      osm_building: [0.10, "The building is from OpenStreetMap, not a machine-learned footprint."],
      single_building_store: [0.10, "The building is small enough to be one store, not several tenants."],
      plausible_building: [0.15, "The building is big enough to be a store, not a kiosk or canopy."],
      mapped_parking: [0.15, "Mapped parking is inside the premises."],
      road_frontage: [0.15, "At least one side of the premises runs along a public road."],
      no_homes_next_door: [0.10, "No home borders the lot."],
      no_warnings: [0.05, "Validation raised no warnings (size, shape and position look typical)."],
    }.freeze

    module_function

    # [score, factors]: the score rounded to 2 places, and every factor as
    # { name:, met:, weight: }.
    def assess(result)
      factors = met(result).map { |name, ok| { name: name, met: ok, weight: FACTORS.fetch(name)[0] } }
      lost = factors.reject { |f| f[:met] }.sum { |f| f[:weight] }
      [[1.0 - lost, 0.0].max.round(2), factors]
    end

    def met(result)
      flags = result.flags
      details = result.details || {}
      {
        valid: result.ok?, main_method: !flags.include?(:fallback),
        building_under_pin: !flags.include?(:building_not_under_pin), full_data: !flags.include?(:partial_data),
        osm_building: !flags.include?(:ml_footprint),
        single_building_store: !flags.intersect?(%i[large_building store_may_be_unit]),
        plausible_building: !flags.include?(:small_building),
        mapped_parking: details[:parking_area_m2].to_f.positive?, road_frontage: details[:frontage_m].to_f.positive?,
        no_homes_next_door: !flags.include?(:near_houses), no_warnings: result.validation.warnings.empty?
      }
    end
  end
end
