# frozen_string_literal: true

module Curtilage
  # Polygons a person drew or fixed, used instead of generating (generate's
  # corrections:, the command line's --corrections): validated like any
  # polygon and marked manual, so the few bad sites can be fixed once and
  # the rest trusted.
  module Corrections
    module_function

    # A Result for a corrected premises ring (and optionally a store ring)
    # at pin: method :manual, provenance data source "manual". Not ok? if
    # the ring fails validation; a store ring that isn't inside the
    # premises is dropped, with a step saying so.
    def result(pin, ring, store_ring: nil, validation: {})
      pin = Validation.pin(pin)
      log = Generator::Log.new([], [], nil, [])
      log.note("manual: a corrected polygon, not generated", step: "manual")
      checked = Validation.check(pin, ring, **validation)
      Result.new(method_name: :manual, pin: pin, ring: (ring if checked.errors != ["missing"]),
                 store_ring: store(pin, ring, store_ring, checked, log), flags: log.flags,
                 explanation: log.notes, steps: log.steps, validation: checked, building: nil,
                 provenance: { gem_version: VERSION, data: { source: "manual" } })
    end

    def store(pin, ring, store_ring, checked, log)
      return nil unless store_ring && checked.ok?

      premises = Geometry.open_ring(Geometry.project(ring, pin))
      inside = Validation.shape_errors(pin, store_ring).empty? &&
               Geometry.open_ring(Geometry.project(store_ring, pin)).all? do |p|
                 Geometry.contains?(premises, p) || Geometry.distance_to_edges(premises, p) < 0.01
               end
      return store_ring if inside

      log.note("dropped the corrected store zone: it isn't a valid ring inside the premises", step: "manual")
      nil
    end

    # corrections: { pin index => ring, or { ring:, store_ring: } }, checked
    # against the number of pins.
    def checked(corrections, size)
      raise ArgumentError, "corrections must be a Hash of pin index => ring" unless corrections.is_a?(Hash)

      corrections.to_h do |index, value|
        unless index.is_a?(Integer) && index.between?(0, size - 1)
          raise ArgumentError, "corrections: #{index.inspect} isn't a pin index (0 to #{size - 1})"
        end

        value = { ring: value } if value.is_a?(Array)
        raise ArgumentError, "corrections: #{index}: a ring or { ring:, store_ring: }" unless value.is_a?(Hash)

        [index, value.slice(:ring, :store_ring)]
      end
    end
  end
end
