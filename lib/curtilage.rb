# frozen_string_literal: true

require_relative "curtilage/version"
require_relative "curtilage/geometry"
require_relative "curtilage/validation"
require_relative "curtilage/features"
require_relative "curtilage/generator"

# Premises generation from OpenStreetMap data. Coordinates are [lng, lat]
# throughout, matching GeoJSON.
module Curtilage
  # Premises for a pin: the recommended method with its fallback
  # (Generator.propose), or one named method (Generator.generate).
  def self.generate(pin, features, method: nil, **)
    method ? Generator.generate(method, pin, features, **) : Generator.propose(pin, features, **)
  end
end
