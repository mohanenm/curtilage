# frozen_string_literal: true

module Curtilage
  # Checks a premises polygon against its site pin. Used on every generated
  # polygon before it's offered, and usable on hand-drawn ones.
  #
  # Errors mean the polygon must not be used. Warnings mean a person should
  # look before using it. Defaults come from hand-drawn premises for
  # standalone stores (typically 2,000-15,000 m2, 4-10 vertices, pin inside).
  module Validation
    Result = Struct.new(:errors, :warnings, :metrics) do
      def ok?
        errors.empty?
      end
    end

    DEFAULTS = {
      min_area_m2: 1_000,      # warn below
      max_area_m2: 40_000,     # warn above
      max_area_error_m2: 100_000, # error above: a block, not a store's lot
      max_vertex_distance_m: 1_000, # error above
      max_vertices: 50,        # error above
      off_centre_m: 200,       # warn above
      swap_far_m: 10_000,
      swap_near_m: 1_000,
    }.freeze

    # A number written as text: plain decimal, optionally with an exponent.
    # Ruby's Float() also takes hex ("0x1A") and underscores ("1_0"), which
    # in a pin list are mistakes, not numbers.
    DECIMAL = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/

    module_function

    # The pin as [lng, lat] floats, or ArgumentError: two finite numbers (or
    # decimal strings), longitude within 180 and latitude within 90. Every
    # entry point checks pins through here.
    def pin(pin)
      raise ArgumentError, "a pin is [lng, lat]: #{pin.inspect}" unless pin.is_a?(Array) && pin.size >= 2

      lng, lat = pin.first(2).map { |v| coordinate(v, pin) }
      raise ArgumentError, "pin out of range (longitude first): #{pin.inspect}" unless lng.abs <= 180 && lat.abs <= 90

      [lng, lat]
    end

    def coordinate(value, pin)
      number = case value
               when Numeric then value.to_f
               when String then value.strip.match?(DECIMAL) ? Float(value.strip) : nil
               end
      raise ArgumentError, "a pin is two numbers: #{pin.inspect}" unless number&.finite?

      number
    end

    # pin: [lng, lat]. ring: [[lng, lat], ...], closed or not.
    def check(pin, ring, **options)
      opts = DEFAULTS.merge(options)
      return Result.new(["missing"], [], {}) if ring.nil? || ring.empty?
      return Result.new(["invalid_coordinates"], [], {}) unless Geometry.valid_coordinates?(ring)

      errors = Geometry.closed?(ring) ? [] : ["unclosed"]
      open = Geometry.open_ring(ring)
      return Result.new(errors + ["too_few_points"], [], {}) if open.uniq.size < 3

      xy = Geometry.project(open, pin)
      metrics = measure(xy).merge(points: open.size)
      errors << "swapped" if swapped?(open, pin, xy, opts)
      errors << "self_intersecting" if Geometry.self_intersects?(xy)
      Result.new(errors + metric_errors(metrics, opts), metric_warnings(metrics, opts), metrics)
    end

    def metric_errors(metrics, opts)
      errors = []
      errors << "pin_outside" unless metrics[:pin_inside]
      errors << "too_far_from_pin" if metrics[:max_vertex_distance_m] > opts[:max_vertex_distance_m]
      errors << "too_many_vertices" if metrics[:points] > opts[:max_vertices]
      errors << "too_large" if metrics[:area_m2] > opts[:max_area_error_m2]
      errors
    end

    def metric_warnings(metrics, opts)
      warnings = []
      warnings << "small" if metrics[:area_m2] < opts[:min_area_m2]
      warnings << "large" if metrics[:area_m2] > opts[:max_area_m2]
      warnings << "off_centre" if metrics[:centroid_offset_m] > opts[:off_centre_m]
      warnings
    end

    def measure(xy)
      origin = [0.0, 0.0]
      rect = Geometry.minimum_rectangle(xy)
      mbr_area, orientation = rect ? [rect[:area], (rect[:angle] * 180 / Math::PI) % 180] : [0.0, 0.0]
      area = Geometry.area(xy)
      {
        area_m2: area.round,
        rectangularity: mbr_area.positive? ? (area / mbr_area).round(3) : nil,
        orientation_deg: orientation.round,
        pin_inside: Geometry.contains?(xy, origin),
        max_vertex_distance_m: xy.map { |x, y| Math.hypot(x, y) }.max.round,
        centroid_offset_m: Math.hypot(*Geometry.centroid(xy)).round,
      }
    end

    # The ring is far from the pin, but the same ring with lng/lat swapped
    # lands on it: the classic [lat, lng] mistake.
    def swapped?(open, pin, xy, opts)
      return false if Math.hypot(*Geometry.centroid(xy)) < opts[:swap_far_m]

      swapped = open.map(&:reverse)
      return false unless Geometry.valid_coordinates?(swapped)

      Math.hypot(*Geometry.centroid(Geometry.project(swapped, pin))) < opts[:swap_near_m]
    end
  end
end
