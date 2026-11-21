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

    # What the parking steps need about the site being generated.
    Site = Struct.new(:features, :target, :opts, :log)

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

    # Roughly half a carriageway (lanes, turn lane, kerb) by road class, so
    # premises stop near the kerb rather than mid-street. The shapefiles carry
    # no width or lane count, so this is a typical figure, not a measurement.
    ROAD_HALF_WIDTH_M = {
      "motorway" => 12, "trunk" => 10, "primary" => 9, "secondary" => 8, "tertiary" => 7,
      "unclassified" => 5, "residential" => 5, "link" => 5
    }.freeze

    DEFAULTS = {
      building_max_distance_m: 30,   # use the nearest building only this close
      large_building_m2: 1_500,      # flag: likely shared (strip mall, multi-tenant)
      pin_clearance_m: 5,            # keep this much room around the pin
      grow_m: 30,                    # grow_trim: how far to grow before trimming
      road_offset_m: nil,            # trim this far short of road centrelines; nil: by road class
      neighbour_min_area_m2: 40,     # grow_trim: smaller buildings (sheds) don't bound a lot
      parking_reach_m: 20,           # grow_trim: parking this close (an aisle and a walkway) is its lot
      parking_max_extent_m: 60,      # grow_trim: claim parking at most this far from the building
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

      rect = target.rectangle
      grown = Geometry.oriented_box(rect[:corners], rect[:angle], opts[:grow_m])
      log.note("grew the building rectangle by #{opts[:grow_m]} m")
      poly = Geometry.counter_clockwise(Geometry.convex_hull(grown + pin_square(opts)))
      poly = trim_at_roads(poly, features, target, opts, log)
      poly = trim_at_neighbours(poly, features, target, opts, log)
      lots = own_parking(features, target, opts, log)
      poly = add_parking(poly, lots, Site.new(features, target, opts, log)) unless lots.empty?
      [poly, target]
    end

    # Mapped parking that touches the building or holds the pin is the
    # site's lot.
    def own_parking(features, target, opts, log)
      features.parking.select do |lot|
        mine = Geometry.contains?(lot.xy, [0.0, 0.0]) || Geometry.overlap?(lot.xy, target.xy) ||
               Geometry.closest_points(lot.xy, target.xy).first <= opts[:parking_reach_m]
        log.note("parking #{lot.id} (#{lot.area.round} m2) touches the building, so it's part of the lot") if mine
        mine
      end
    end

    # Claims the site's parking up to the kerb (at most parking_max_extent_m
    # from the building), splitting a lot halfway where it also touches a
    # neighbour, then keeps clear of neighbouring buildings.
    def add_parking(poly, lots, site)
      rect = site.target.rectangle
      reach = Geometry.oriented_box(rect[:corners], rect[:angle], site.opts[:parking_max_extent_m])
      fence = trim_at_roads(Geometry.counter_clockwise(reach), site.features, site.target, site.opts, Log.new([], []))
      parts = lots.map { |lot| share_lot(Geometry.clip_convex(lot.xy, fence), lot, site) }
      grown = Geometry.counter_clockwise(Geometry.convex_hull(poly + parts.select { |p| p.size >= 3 }.flatten(1)))
      keep_off_neighbours(grown, site.features, site.target, site.opts, site.log)
    end

    def share_lot(part, lot, site)
      features, target, opts, log = site.to_a
      neighbours(features, target, opts).each do |other|
        next if Geometry.overlap?(other.hull, target.hull)
        next unless Geometry.overlap?(lot.xy, other.xy) ||
                    Geometry.closest_points(lot.xy, other.xy).first <= opts[:parking_reach_m]

        log.note("parking #{lot.id} also touches building #{other.id}: split halfway")
        part = split_from_neighbour(part, target.hull, other.hull, target.rectangle[:angle]) if part.size >= 3
      end
      part
    end

    # Stops 1 m short of any neighbouring building the lot reached.
    def keep_off_neighbours(poly, features, target, opts, log)
      neighbours(features, target, opts).each do |other|
        next if Geometry.overlap?(other.hull, target.hull) || !Geometry.overlap?(other.hull, poly)

        trimmed = split_from_neighbour(poly, target.hull, other.hull, target.rectangle[:angle],
                                       stop: ->(near, far) { [far - 1, near].max })
        next if trimmed.size < 3

        log.note("stopped 1 m short of building #{other.id}")
        poly = trimmed
      end
      poly
    end

    def neighbours(features, target, opts)
      features.buildings.reject { |b| b.equal?(target) || b.area < opts[:neighbour_min_area_m2] }
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
      [trim_at_roads(poly, features, target, opts, log), target]
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

    def trim_at_roads(poly, features, target, opts, log)
      features.roads.each do |road|
        next unless PUBLIC_HIGHWAYS.include?(road.highway)

        road.xy.each_cons(2) do |a, b|
          next unless segment_meets_polygon?(a, b, poly)

          trimmed, offset = trim_at_segment(poly, [a, b], target, road_offset(road, opts))
          if trimmed.nil?
            log.note("kept the part beyond #{road_label(road)}: it would cut the building")
            next
          end
          next if trimmed.size < 3

          label = "trimmed at #{road_label(road)}, #{offset.round} m short of its centreline"
          log.note(label) unless log.notes.include?(label)
          poly = trimmed
        end
      end
      poly
    end

    # Clips at the segment's line, moved toward the pin by up to offset
    # metres but never into the building. Returns [polygon, offset used], or
    # nil when the road's centreline itself would cut the building.
    def trim_at_segment(poly, segment, target, offset)
      origin, normal = road_half_plane(*segment, 0)
      return [poly, 0] unless normal

      origin, normal = square_to_building(segment, origin, normal, target.rectangle[:angle])
      building_side = target.hull.map { |p| side(p, origin, normal) }.max
      return nil if building_side > 0.5

      offset = offset.clamp(0, [-building_side, 0].max)
      origin = [origin[0] - (normal[0] * offset), origin[1] - (normal[1] * offset)]
      [Geometry.clip_half_plane(poly, origin, normal), offset]
    end

    # A road running within 30 degrees of a building side is cut square to
    # that side, at the segment's end nearest the pin, so a slanted stretch
    # near a junction doesn't leave a diagonal corner. Kept as is otherwise,
    # or when squaring would cut off the pin.
    def square_to_building(segment, origin, normal, angle)
      4.times do |k|
        axis = [Math.cos(angle + (k * Math::PI / 2)), Math.sin(angle + (k * Math::PI / 2))]
        next unless Geometry.dot(axis, normal) > Math.cos(30 * Math::PI / 180)

        near = segment.min_by { |p| Geometry.dot(p, axis) }
        return [near, axis] if Geometry.dot(near, axis).positive?
      end
      [origin, normal]
    end

    # Half the road's width when the caller gives no fixed offset.
    def road_offset(road, opts)
      opts[:road_offset_m] || ROAD_HALF_WIDTH_M.fetch(road.highway, ROAD_HALF_WIDTH_M["link"])
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
      neighbours(features, target, opts).each do |other|
        other_hull = other.hull
        next unless Geometry.overlap?(other_hull, poly)

        if Geometry.overlap?(other_hull, hull)
          log.flag(:attached_building, "building #{other.id} touches the building, so it can't be split off")
          next
        end
        trimmed = split_from_neighbour(poly, hull, other_hull, target.rectangle[:angle])
        next if trimmed.size < 3

        log.note("trimmed halfway to building #{other.id}")
        poly = trimmed
      end
      poly
    end

    HALFWAY = ->(near, far) { (near + far) / 2 }

    # Cuts between the building and a neighbour (halfway by default), square
    # to one of the building's sides (hand-drawn premises are rectangles): of
    # the sides facing the neighbour with a clear gap, the cut that keeps the
    # most lot. Falls back to a cut across the line between their nearest
    # points.
    def split_from_neighbour(poly, hull, other, angle, stop: HALFWAY)
      cuts = 4.times.filter_map { |k| square_cut(poly, hull, other, angle + (k * Math::PI / 2), stop) }
      return cuts.max_by { |c| c.size >= 3 ? Geometry.area(c) : 0 } unless cuts.empty?

      diagonal_cut(poly, hull, other, stop)
    end

    def diagonal_cut(poly, hull, other, stop)
      _, p, q = Geometry.closest_points(hull, other)
      normal = [q[0] - p[0], q[1] - p[1]]
      length = Math.hypot(*normal)
      return poly if length < 1e-6

      normal = normal.map { |v| v / length }
      at = stop.call(Geometry.dot(p, normal), Geometry.dot(q, normal))
      Geometry.clip_half_plane(poly, [normal[0] * at, normal[1] * at], normal)
    end

    # The cut facing direction (radians) where stop puts it in the gap, or
    # nil when the buildings overlap along that direction.
    def square_cut(poly, hull, other, direction, stop)
      normal = [Math.cos(direction), Math.sin(direction)]
      near = hull.map { |p| Geometry.dot(p, normal) }.max
      far = other.map { |p| Geometry.dot(p, normal) }.min
      return nil unless far > near

      at = stop.call(near, far)
      Geometry.clip_half_plane(poly, [normal[0] * at, normal[1] * at], normal)
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
