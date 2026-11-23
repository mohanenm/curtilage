# frozen_string_literal: true

module Curtilage
  # Optional zones around and inside the premises for arrival detection,
  # nested by construction: approach (premises grown, "customer is near")
  # holds the premises ("arrived"), which hold the store zone and the pickup
  # zone. Off by default (approach_m:, pickup_m:).
  module Generator
    DEFAULT_APPROACH_M = 150
    DEFAULT_PICKUP_M = 25
    # The approach zone is simplified to at most this many corners.
    MAX_APPROACH_VERTICES = 16
    # Parking pieces smaller than this (about one space) aren't a pickup zone.
    MIN_PICKUP_M2 = 25

    module_function

    # The premises grown by approach_m, simplified only by dropping corners
    # that keep every premises corner inside (so it still holds them).
    def approach_xy(premises, opts)
      grown = Geometry.round_buffer(premises, opts[:approach_m])
      Geometry.simplify_containing(grown, MAX_APPROACH_VERTICES, premises)
    end

    # Neither data source maps pickup or curbside spots, so the zone is
    # estimated: the largest piece of mapped parking within pickup_m of the
    # building, kept inside the premises like the store zone. nil without
    # mapped parking there.
    def pickup_xy(target, premises, features, opts, log)
      rect = target.rectangle
      reach = Geometry.counter_clockwise(Geometry.oriented_box(rect[:corners], rect[:angle], opts[:pickup_m]))
      pieces = features.parking.map do |lot|
        piece = Geometry.clip_convex(lot.xy, reach)
        [lot, Geometry.clean(Geometry.clip_inside(piece, premises, store_margin(opts[:precision])))]
      end
      lot, best = pieces.select { |_, xy| m2(xy) >= MIN_PICKUP_M2 }.max_by { |_, xy| m2(xy) }
      note_pickup(log, lot, best, opts)
      best
    end

    def note_pickup(log, lot, xy, opts)
      unless xy
        return log.note("no pickup zone: no mapped parking within #{opts[:pickup_m]} m of the building",
                        step: "pickup_zone", rule: "pickup_m", distance_m: opts[:pickup_m])
      end

      log.note("pickup zone estimated from parking #{lot.id} within #{opts[:pickup_m]} m of the building " \
               "(#{m2(xy)} m2)", step: "pickup_zone", rule: "pickup_m", features: [lot.id],
                                 distance_m: opts[:pickup_m], area_after_m2: m2(xy))
    end

    def add_zones(result, shape, opts, log)
      premises, target, features = shape
      if opts[:approach_m]
        xy = approach_xy(premises, opts)
        log.note("approach zone: the premises grown by #{opts[:approach_m]} m",
                 step: "approach_zone", rule: "approach_m", distance_m: opts[:approach_m], area_after_m2: m2(xy))
        result.approach_ring = zone_ring(xy, "approach", result.pin, opts, log)
      end
      return unless opts[:pickup_m] && target

      pickup = pickup_xy(target, premises, features, opts, log)
      result.pickup_ring = zone_ring(pickup, "pickup", result.pin, opts, log)
      result.staging_point = staging_point(pickup, target, result.pin, opts, log) if result.pickup_ring
    end

    # Where a driver might wait: the pickup zone's point nearest the
    # building. Estimated like the zone (no entrances are mapped).
    def staging_point(pickup, target, pin, opts, log)
      distance, point, = Geometry.closest_points(pickup, target.hull)
      log.note("staging point: the pickup zone's nearest point to the building, #{distance.round} m from it",
               step: "staging_point", features: [target.id], distance_m: distance.round(1))
      Geometry.lnglat([point], pin, opts[:precision]).first
    end

    def ring_of(xy, pin, precision)
      ring = Geometry.lnglat(xy, pin, precision)
      ring << ring.first
    end

    # A zone as a ring, or nil (with a note) if it isn't a usable shape.
    def zone_ring(xy, name, pin, opts, log)
      return nil unless xy && xy.size >= 3

      ring = ring_of(xy, pin, opts[:precision])
      problems = Validation.shape_errors(pin, ring)
      return ring if problems.empty?

      log.note("dropped the #{name} zone: #{problems.join(", ")}", step: "#{name}_zone")
      nil
    end
  end
end
