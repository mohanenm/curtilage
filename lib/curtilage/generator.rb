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
      "unclassified" => 5, "residential" => 5, "link" => 5,
      # Railways: the track bed plus clearance to the lineside fence.
      "rail" => 5, "light_rail" => 4, "subway" => 4, "narrow_gauge" => 3
    }.freeze

    DEFAULTS = {
      building_max_distance_m: 30,   # use the nearest building only this close
      large_building_m2: 1_500,      # flag: likely shared (strip mall, multi-tenant)
      pin_clearance_m: 5,            # keep this much room around the pin
      grow_m: 30,                    # grow_trim: how far to grow before trimming
      road_offset_m: nil,            # trim this far short of road centrelines; nil: by road class
      neighbour_min_area_m2: 40,     # grow_trim: smaller buildings (sheds) don't bound a lot
      neighbour_gap_m: 3,            # grow_trim: strip left to a neighbouring building (nil: halfway)
      neighbour_strip_min_area_m2: 0, # grow_trim: smaller neighbours are split halfway
      parking_reach_m: 20,           # grow_trim: parking this close (an aisle and a walkway) is its lot
      parking_max_extent_m: 60,      # grow_trim: claim parking at most this far from the building
      building_margin_m: 20,         # building: margin around its rectangle
      box_side_m: 60,                # box: side of the square around the pin
      max_vertices: 10,
      buildings: :osm,               # :osm, :osm_filled (ML footprints where OSM has none) or :ml
    }.freeze

    BUILDING_SOURCES = %i[osm osm_filled ml].freeze

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
      unless BUILDING_SOURCES.include?(opts[:buildings])
        raise ArgumentError, "unknown buildings: #{opts[:buildings].inspect} (have: #{BUILDING_SOURCES.join(", ")})"
      end

      features = Features.new(pin, features) unless features.is_a?(Features)
      features = choose_buildings(features, opts[:buildings])
      log = Log.new([], [])
      log.note("dropped #{features.dropped} unusable OSM features") if features.dropped.positive?
      xy, target = send(method, features, opts, log)
      finish(method, pin, [xy, target], log, opts)
    end

    # The building flavour: OSM only (default), OSM filled in with ML
    # footprints that don't overlap any OSM building, or ML footprints only.
    def choose_buildings(features, source)
      case source
      when :osm then features
      when :ml then features.with_buildings(features.ml_buildings)
      else
        extra = features.ml_buildings.reject do |m|
          features.buildings.any? { |b| b.near?(m) && Geometry.overlap?(b.hull, m.hull) }
        end
        features.with_buildings(features.buildings + extra)
      end
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
      if target&.kind == "ml_building"
        log.flag(:ml_footprint, "building #{target.id} is a machine-learned footprint, not mapped in OSM: " \
                                "check it exists")
      end
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

    # Cuts along each public road's stretch beside the site, following its
    # overall direction: premises line up with the kerb, which may be at an
    # angle to the building. A stretch within ROAD_SNAP_DEG of a building side
    # is snapped square to it, so short bends at junctions average out.
    #
    # Stretches are applied nearest first: once the nearest road has trimmed
    # the polygon, a road beyond it (say the far side of a junction) no
    # longer reaches it, so its extended line can't slice across the lot.
    def trim_at_roads(poly, features, target, opts, log)
      road_stretches(features, target, opts).each do |road, run, offset|
        next unless run.any? { |p| Geometry.contains?(poly, p) || Geometry.distance_to_edges(poly, p) < offset }

        trimmed, used = trim_along(poly, fit_direction(run, target), target, offset)
        next log.note("kept the part beyond #{road_label(road)}: it would cut the building") unless trimmed
        next if trimmed.size < 3

        label = "trimmed at #{road_label(road)}, #{used.round} m short of its centreline"
        log.note(label) unless log.notes.include?(label)
        poly = trimmed
      end
      poly
    end

    # [road, stretch points, offset] for every public road and railway near
    # the building, nearest stretch first.
    def road_stretches(features, target, opts)
      (features.roads.select { |road| PUBLIC_HIGHWAYS.include?(road.highway) } + features.railways)
        .flat_map { |road| road_runs(road, target).map { |run| [road, run, road_offset(road, opts)] } }
        .sort_by { |_, run, _| run.map { |p| Geometry.distance_to_edges(target.hull, p) }.min }
    end

    ROAD_REACH_M = 60   # only the road this close to the building bounds the site
    ROAD_BEND_DEG = 30  # a sharper turn starts a new stretch
    ROAD_SNAP_DEG = 5   # a stretch this close to a building side is squared to it

    # Points every 2 m along the road within reach of the building, split
    # into stretches wherever the road turns by more than ROAD_BEND_DEG.
    def road_runs(road, target)
      runs = []
      run = nil
      road.xy.each_cons(2) do |a, b|
        heading = Math.atan2(b[1] - a[1], b[0] - a[0]) % Math::PI
        samples(a, b).each do |p|
          if Geometry.distance_to_edges(target.hull, p) > ROAD_REACH_M
            run = nil
            next
          end
          if run.nil? || angle_between(run[:heading], heading) > ROAD_BEND_DEG * Math::PI / 180
            run = { heading: heading, points: [] }
            runs << run
          end
          run[:points] << p
        end
      end
      runs.map { |r| r[:points] }.select { |pts| pts.size >= 2 }
    end

    def samples(a, b)
      n = [(Math.hypot(b[0] - a[0], b[1] - a[1]) / 2).ceil, 1].max
      (0..n).map { |i| Geometry.lerp(a, b, i.fdiv(n)) }
    end

    # Smallest angle between two undirected headings (radians, mod pi).
    def angle_between(first, second)
      d = (first - second).abs % Math::PI
      [d, Math::PI - d].min
    end

    # [centroid, unit direction] of the stretch's best-fit line, snapped to a
    # building side when nearly parallel.
    def fit_direction(points, target)
      centre = Geometry.centroid(points)
      heading = principal_heading(points, centre)
      axis = target.rectangle[:angle]
      2.times do |k|
        side = axis + (k * Math::PI / 2)
        heading = side if angle_between(heading % Math::PI, side % Math::PI) <= ROAD_SNAP_DEG * Math::PI / 180
      end
      [centre, [Math.cos(heading), Math.sin(heading)]]
    end

    # Direction of greatest spread (the first principal axis), in radians.
    def principal_heading(points, centre)
      cx, cy = centre
      sxx = points.sum { |x, _| (x - cx)**2 }
      syy = points.sum { |_, y| (y - cy)**2 }
      sxy = points.sum { |x, y| (x - cx) * (y - cy) }
      0.5 * Math.atan2(2 * sxy, sxx - syy)
    end

    # Clips at the line, moved toward the pin by up to offset metres but
    # never into the building. Returns [polygon, offset used], [poly, 0]
    # when the pin is on the line, or nil when the centreline itself would
    # cut the building.
    def trim_along(poly, line, target, offset)
      origin, direction = line
      normal = [direction[1], -direction[0]]
      pin_side = side([0.0, 0.0], origin, normal)
      return [poly, 0] if pin_side.abs < 1e-6

      normal = normal.map(&:-@) if pin_side.positive?
      building_side = target.hull.map { |p| side(p, origin, normal) }.max
      return nil if building_side > 0.5

      offset = offset.clamp(0, [-building_side, 0].max)
      origin = [origin[0] - (normal[0] * offset), origin[1] - (normal[1] * offset)]
      [Geometry.clip_half_plane(poly, origin, normal), offset]
    end

    # Half the road's width when the caller gives no fixed offset.
    def road_offset(road, opts)
      opts[:road_offset_m] || ROAD_HALF_WIDTH_M.fetch(road.highway, ROAD_HALF_WIDTH_M["link"])
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
        strip = neighbour_strip(other, opts)
        trimmed = split_from_neighbour(poly, hull, other_hull, target.rectangle[:angle], stop: strip_stop(strip))
        next if trimmed.size < 3

        log.note(strip ? "stopped #{strip} m short of building #{other.id}" : "trimmed halfway to building #{other.id}")
        poly = trimmed
      end
      poly
    end

    HALFWAY = ->(near, far) { (near + far) / 2 }

    # The strip left to a neighbour, or nil to split halfway. Pavement
    # between two buildings usually belongs to one of them, and the site's
    # own lot is the likelier owner, so claim it up to a narrow strip.
    # Small neighbours (houses, below neighbour_strip_min_area_m2) keep the
    # halfway split: their yard isn't the site's.
    def neighbour_strip(other, opts)
      gap = opts[:neighbour_gap_m]
      gap if gap && other.area >= opts[:neighbour_strip_min_area_m2]
    end

    # Never less than halfway: a narrow gap is still split down the middle.
    def strip_stop(strip)
      return HALFWAY unless strip

      ->(near, far) { [(near + far) / 2, far - strip].max }
    end

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

    def side(point, origin, normal)
      ((point[0] - origin[0]) * normal[0]) + ((point[1] - origin[1]) * normal[1])
    end

    def pin_square(opts)
      c = opts[:pin_clearance_m]
      [[-c, -c], [c, -c], [c, c], [-c, c]]
    end

    def road_label(road)
      kind = PUBLIC_HIGHWAYS.include?(road.highway) ? "road" : "railway"
      name = road.name.to_s.empty? ? "#{kind} #{road.id}" : road.name
      "#{name} (#{road.highway})"
    end
  end
end
