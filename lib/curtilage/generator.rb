# frozen_string_literal: true

module Curtilage
  # Proposes a premises polygon for a pin from the OSM features around it.
  #
  # Methods are pure functions of (pin, features, options). Each returns a
  # Result with the ring ([lng, lat], closed), a step-by-step explanation,
  # review flags and the validation result. Outputs are convex, which keeps
  # clipping simple and matches hand-drawn premises (near-rectangles that line
  # up with the building).
  #
  # Compared against hand-drawn premises, grow_trim was the best method and
  # building the best fallback. box is only a baseline: it crosses public
  # roads on most sites, so propose never offers it.
  module Generator
    Result = Struct.new(:method_name, :ring, :explanation, :flags, :validation, :building, keyword_init: true) do
      def ok?
        !ring.nil? && validation.ok?
      end
    end

    # Notes explain each step; flags are reasons a person should look first.
    Log = Struct.new(:notes, :flags) do
      def note(text) = notes << text

      def flag(name, text)
        flags << name unless flags.include?(name)
        notes << text
      end
    end

    METHODS = %i[grow_trim building box].freeze
    CHAIN = %i[grow_trim building].freeze

    PUBLIC_HIGHWAYS = %w[
      motorway trunk primary secondary tertiary unclassified residential
      motorway_link trunk_link primary_link secondary_link tertiary_link
    ].freeze

    DEFAULTS = {
      building_max_distance_m: 30,   # use the nearest building only this close
      large_building_m2: 1_500,      # flag: likely shared (strip mall, multi-tenant)
      pin_clearance_m: 5,            # keep this much room around the pin
      grow_m: 35,                    # grow_trim: how far to grow before trimming
      road_offset_m: 0,              # grow_trim: trim this far short of the road centreline
      neighbour_min_area_m2: 40,     # grow_trim: smaller buildings (sheds) don't bound a lot
      building_margin_m: 20,         # building: margin around its rectangle
      box_side_m: 60,                # box: side of the square around the pin
      max_vertices: 10,
    }.freeze

    module_function

    # The recommended path: grow_trim, falling back to building when its
    # result fails validation. Returns the first valid result, else the last
    # attempt (not ok?, with every attempt's explanation).
    def propose(pin, features, **)
      features = Features.new(pin, features) unless features.is_a?(Features)
      failures = []
      CHAIN.each do |method|
        result = generate(method, pin, features, **)
        if result.ok?
          unless failures.empty?
            result.flags.unshift(:fallback)
            result.explanation.unshift(*failures)
          end
          return result
        end
        failures << "#{method} failed (#{failure_reason(result)})"
        return result.tap { |r| r.explanation = failures + r.explanation } if method == CHAIN.last
      end
    end

    # One method, no fallback. features: a Curtilage::Features or the raw list.
    def generate(method, pin, features, **options)
      raise ArgumentError, "unknown method #{method.inspect}" unless METHODS.include?(method)

      opts = DEFAULTS.merge(options)
      features = Features.new(pin, features) unless features.is_a?(Features)
      log = Log.new([], [])
      log.note("dropped #{features.dropped} unusable OSM features") if features.dropped.positive?
      xy, target = send(method, features, opts, log)
      finish(method, pin, [xy, target], log, opts)
    end

    def finish(method, pin, shape, log, opts)
      xy, target = shape
      result = Result.new(method_name: method, explanation: log.notes, flags: log.flags, building: target&.id)
      unless xy
        result.validation = Validation.check(pin, nil)
        return result
      end

      xy = Geometry.clean(Geometry.counter_clockwise(xy))
      if xy.size > opts[:max_vertices]
        log.note("simplified #{xy.size} vertices to #{opts[:max_vertices]}")
        xy = Geometry.simplify(xy, opts[:max_vertices])
      end
      result.ring = Geometry.unproject(xy, pin).map { |lng, lat| [lng.round(7), lat.round(7)] }
      result.ring << result.ring.first
      result.validation = Validation.check(pin, result.ring)
      result
    end

    def failure_reason(result)
      return result.explanation.last if result.ring.nil?

      result.validation.errors.join(", ")
    end

    # Grow from the building toward its lot, then trim at public roads (the
    # premises never cross one) and halfway to neighbouring buildings.
    def grow_trim(features, opts, log)
      target = find_building(features, opts, log)
      return [nil, nil] unless target

      rect = Geometry.minimum_rectangle(target.xy)
      grown = Geometry.oriented_box(rect[:corners], rect[:angle], opts[:grow_m])
      log.note("grew the building rectangle by #{opts[:grow_m]} m")
      poly = Geometry.counter_clockwise(Geometry.convex_hull(grown + pin_square(opts)))
      poly = trim_at_roads(poly, features, target.hull, opts, log)
      poly = trim_at_neighbours(poly, features, target, opts, log)
      [poly, target]
    end

    # The building's minimum rectangle plus a margin, trimmed at public
    # roads (premises never cross one).
    def building(features, opts, log)
      target = find_building(features, opts, log)
      return [nil, nil] unless target

      rect = Geometry.minimum_rectangle(target.xy)
      log.note("building rectangle grown by #{opts[:building_margin_m]} m")
      box = Geometry.oriented_box(rect[:corners], rect[:angle], opts[:building_margin_m])
      poly = Geometry.counter_clockwise(Geometry.convex_hull(box + pin_square(opts)))
      [trim_at_roads(poly, features, target.hull, opts, log), target]
    end

    # A square around the pin: the baseline the other methods must beat.
    def box(_features, opts, log)
      half = opts[:box_side_m] / 2.0
      log.note("square of #{opts[:box_side_m]} m around the pin")
      [[[-half, -half], [half, -half], [half, half], [-half, half]], nil]
    end

    # The smallest building under the pin, else the nearest one close enough.
    # Flags a large one: the site may be one unit of it.
    def find_building(features, opts, log)
      target = building_under_pin(features, log) || nearest_building(features, opts, log)
      if target && target.area > opts[:large_building_m2]
        log.flag(:large_building, "building is over #{opts[:large_building_m2]} m2: if it's shared " \
                                  "(strip mall, several tenants), check which part is the site")
      end
      target
    end

    def building_under_pin(features, log)
      target = features.buildings.select { |b| Geometry.contains?(b.xy, [0.0, 0.0]) }.min_by(&:area)
      log.note("building #{target.id} is under the pin (#{target.area.round} m2)") if target
      target
    end

    def nearest_building(features, opts, log)
      distance, target = features.buildings.map { |b| [Geometry.distance_to_edges(b.xy, [0.0, 0.0]), b] }
                                 .min_by(&:first)
      if target && distance <= opts[:building_max_distance_m]
        log.flag(:building_not_under_pin, "no building under the pin; using building #{target.id}, " \
                                          "#{distance.round} m away (#{target.area.round} m2)")
        target
      else
        log.note("no building within #{opts[:building_max_distance_m]} m of the pin")
        nil
      end
    end

    def trim_at_roads(poly, features, hull, opts, log)
      features.roads.each do |road|
        next unless PUBLIC_HIGHWAYS.include?(road.highway)

        road.xy.each_cons(2) do |a, b|
          next unless segment_meets_polygon?(a, b, poly)

          origin, normal = road_half_plane(a, b, opts[:road_offset_m])
          next unless normal

          if hull.any? { |p| side(p, origin, normal) > 0.5 }
            log.note("kept the part beyond #{road_label(road)}: it would cut the building")
            next
          end
          trimmed = Geometry.clip_half_plane(poly, origin, normal)
          next if trimmed.size < 3

          label = "trimmed at #{road_label(road)}"
          log.note(label) unless log.notes.last == label
          poly = trimmed
        end
      end
      poly
    end

    # The half-plane on the pin's side of the road segment's line, moved
    # offset metres toward the pin. nil when the pin is on the line.
    def road_half_plane(a, b, offset)
      normal = [b[1] - a[1], a[0] - b[0]]
      length = Math.hypot(*normal)
      return [nil, nil] if length < 1e-6

      normal = normal.map { |v| v / length }
      pin_side = side([0.0, 0.0], a, normal)
      return [nil, nil] if pin_side.abs < 1e-6

      normal = normal.map(&:-@) if pin_side.positive?
      [[a[0] - (normal[0] * offset), a[1] - (normal[1] * offset)], normal]
    end

    def trim_at_neighbours(poly, features, target, opts, log)
      hull = target.hull
      features.buildings.each do |other|
        next if other.equal?(target) || other.area < opts[:neighbour_min_area_m2]

        other_hull = other.hull
        next unless Geometry.overlap?(other_hull, poly)

        if Geometry.overlap?(other_hull, hull)
          log.flag(:attached_building, "building #{other.id} touches the building, so it can't be split off")
          next
        end
        trimmed = Geometry.clip_half_plane(poly, *separating_line(hull, other_hull))
        next if trimmed.size < 3

        log.note("trimmed halfway to building #{other.id}")
        poly = trimmed
      end
      poly
    end

    # The line halfway between two disjoint hulls, as [origin, normal] with
    # the first hull on the kept side.
    def separating_line(hull, other)
      _, p, q = Geometry.closest_points(hull, other)
      [[(p[0] + q[0]) / 2, (p[1] + q[1]) / 2], [q[0] - p[0], q[1] - p[1]]]
    end

    def segment_meets_polygon?(a, b, poly)
      return true if Geometry.contains?(poly, a) || Geometry.contains?(poly, b)

      poly.each_index.any? { |i| Geometry.segments_cross?(a, b, poly[i], poly[(i + 1) % poly.size]) }
    end

    def side(point, origin, normal)
      ((point[0] - origin[0]) * normal[0]) + ((point[1] - origin[1]) * normal[1])
    end

    def pin_square(opts)
      c = opts[:pin_clearance_m]
      [[-c, -c], [c, -c], [c, c], [-c, c]]
    end

    def road_label(road)
      name = road.name.to_s.empty? ? "road #{road.id}" : road.name
      "#{name} (#{road.highway})"
    end
  end
end
