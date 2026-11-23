# frozen_string_literal: true

module Curtilage
  # Proposes a premises polygon for a pin from the OSM features around it.
  #
  # Methods are pure functions of (pin, features, options). Each returns a
  # Result with the premises ring ([lng, lat], closed), the store zone (the
  # building's own outline, always inside the premises), a step-by-step
  # explanation, review flags and the validation result. Premises are convex,
  # which keeps clipping simple and matches hand-drawn premises
  # (near-rectangles that line up with the building).
  #
  # The lot steps live in generator_lot.rb and the store zone in
  # generator_store.rb; they reopen this module.
  #
  # Compared against hand-drawn premises, grow_trim was the best method and
  # building the best fallback.
  module Generator
    # Kept so code written against 0.2 (Curtilage::Generator::Result) works.
    Result = Curtilage::Result

    # What the parking steps need about the site being generated.
    # shared: the lots own_parking found shared with several buildings.
    Site = Struct.new(:features, :target, :opts, :log, :shared)

    # Notes explain each step; flags are reasons a person should look first.
    # access: where driveways taken into the premises meet the street.
    Log = Struct.new(:notes, :flags, :access) do
      def note(text) = notes << text

      def access_point(xy) = (self.access ||= []) << xy

      def flag(name, text)
        flags << name unless flags.include?(name)
        notes << text
      end
    end

    # The methods generate accepts, and the order propose falls back through.
    # Kept apart on purpose: a method can be offered without being a fallback.
    METHODS = %i[grow_trim building].freeze
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

    # A driveway reaches a public road when it comes this close to one.
    ENTRANCE_MAX_M = 15
    # How far beyond the lot a driveway is followed toward the street.
    ENTRANCE_REACH_M = 25

    # Building types (OSM building=*) that are homes: the lot never takes
    # their yards (see home? and behind_home?).
    HOUSE_TYPES = %w[house detached residential semidetached_house terrace bungalow static_caravan cabin
                     apartments].freeze
    # Structures that are part of a site's lot when next to its building:
    # parking garages, carports and canopies (drive-throughs, fuel pumps).
    LOT_TYPES = %w[parking carport roof].freeze

    DEFAULTS = {
      building_max_distance_m: 30,   # use the nearest building only this close
      large_building_m2: 5_000,      # flag: likely shared (strip mall, multi-tenant)
      large_building_note_m2: 1_500, # explanation only, no flag: may be shared
      pin_clearance_m: 5,            # keep this much room around the pin
      building_clearance_m: 3,       # road trims stop at least this far from the building
      grow_m: 30,                    # grow_trim: how far to grow before trimming
      road_offset_m: nil,            # trim this far short of road centrelines; nil: by road class
      neighbour_min_area_m2: 40,     # grow_trim: smaller buildings (sheds) don't bound a lot
      neighbour_gap_m: 3,            # grow_trim: strip left to a neighbouring building (nil: halfway)
      neighbour_strip_min_area_m2: 0, # grow_trim: smaller neighbours are split halfway
      house_max_m2: 250,             # an untyped building smaller than this, among others, may be a home
      house_street_m: 25,            # ... when two more small buildings are this close
      parking_reach_m: 20,           # grow_trim: parking this close (an aisle and a walkway) is its lot
      shared_lot_buildings: 3,       # grow_trim: a lot touching this many other buildings is shared
      small_building_m2: 50,         # flag: a building this small may be a kiosk or shed, not the site
      parking_max_extent_m: 60,      # grow_trim: claim parking at most this far from the building
      building_margin_m: 20,         # building: margin around its rectangle
      max_vertices: 10,              # the premises are simplified to at most this many corners
      store_zone: true,              # also return the building's outline as the store zone
      max_store_vertices: 20,        # the store outline is simplified to at most this many corners
      buildings: :osm,               # :osm, :osm_filled (ML footprints where OSM has none) or :ml
      scope: :site,                  # :site, or :centre (the whole shopping centre when on a shared lot)
      validation: {},                # limits for Validation.check, e.g. { max_area_error_m2: 300_000 }
      precision: 7,                  # decimal places in output coordinates (7: about 1 cm)
    }.freeze

    BUILDING_SOURCES = %i[osm osm_filled ml].freeze
    SCOPES = %i[site centre].freeze

    # Allowed values for the numeric options: [min, max, whole number?].
    # Out-of-range values would make no sense (a negative distance) or make
    # the rules run on a city block.
    DISTANCE = [0, 1_000, false].freeze
    AREA = [0, 10_000_000, false].freeze
    RANGES = {
      building_max_distance_m: DISTANCE, pin_clearance_m: DISTANCE, building_clearance_m: DISTANCE,
      grow_m: DISTANCE, road_offset_m: DISTANCE, neighbour_gap_m: DISTANCE, house_street_m: DISTANCE,
      parking_reach_m: DISTANCE, parking_max_extent_m: DISTANCE, building_margin_m: DISTANCE,
      large_building_m2: AREA, large_building_note_m2: AREA, neighbour_min_area_m2: AREA,
      neighbour_strip_min_area_m2: AREA, house_max_m2: AREA, small_building_m2: AREA,
      shared_lot_buildings: [1, 1_000, true], max_vertices: [4, 50, true], max_store_vertices: [3, 200, true],
      precision: [5, 15, true]
    }.freeze
    # Options where nil means "work it out" (by road class; halfway).
    NIL_ALLOWED = %i[road_offset_m neighbour_gap_m].freeze

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

      pin = Validation.pin(pin)
      opts = checked_options(options)
      features = Features.new(pin, features) unless features.is_a?(Features)
      features = choose_buildings(features, opts[:buildings])
      log = Log.new([], [])
      log.note("dropped #{features.dropped} unusable OSM features") if features.dropped.positive?
      xy, target = send(method, features, opts, log)
      finish(method, pin, [xy, target, features], log, opts)
    end

    # DEFAULTS with the options applied. A misspelt option would otherwise be
    # silently ignored.
    def checked_options(options)
      unknown = options.keys - DEFAULTS.keys
      raise ArgumentError, "unknown option(s): #{unknown.join(", ")} (see Generator::DEFAULTS)" if unknown.any?

      opts = DEFAULTS.merge(options)
      check_choices(opts)
      raise ArgumentError, "validation must be a Hash of limits" unless opts[:validation].is_a?(Hash)

      Validation.limits(opts[:validation])
      RANGES.each { |key, range| check_range(key, opts[key], *range) }
      opts
    end

    def check_choices(opts)
      raise ArgumentError, "unknown scope: #{opts[:scope].inspect} (have: #{SCOPES.join(", ")})" \
        unless SCOPES.include?(opts[:scope])
      raise ArgumentError, "unknown buildings: #{opts[:buildings].inspect} (have: #{BUILDING_SOURCES.join(", ")})" \
        unless BUILDING_SOURCES.include?(opts[:buildings])
      raise ArgumentError, "store_zone must be true or false" unless [true, false].include?(opts[:store_zone])
    end

    def check_range(key, value, min, max, whole)
      return if value.nil? && NIL_ALLOWED.include?(key)

      ok = value.is_a?(Numeric) && value.real? && value.to_f.finite? && value.between?(min, max) &&
           (!whole || value.is_a?(Integer))
      return if ok

      raise ArgumentError, "#{key} must be #{"a whole number " if whole}from #{min} to #{max}: #{value.inspect}"
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
      xy, target, features = shape
      result = Result.new(method_name: method, pin: pin, explanation: log.notes, flags: log.flags,
                          building: target&.id, features: features,
                          provenance: { gem_version: VERSION, features_sha256: features.sha256, options: opts })
      unless xy
        result.validation = Validation.check(pin, nil)
        return result
      end

      premises = premises_xy(xy, target, opts, log)
      result.ring = ring_of(premises, pin, opts[:precision])
      if target && opts[:store_zone]
        result.store_ring = ring_of(store_xy(target, premises, opts, log), pin, opts[:precision])
      end
      result.validation = Validation.check(pin, result.ring, **opts[:validation])
      result.details = details(target, premises, features, pin, log, precision: opts[:precision])
      result
    end

    # The premises always hold the whole building (the store zone has to
    # sit inside them): widened to take it in if needed, and simplified only
    # in ways that keep it and the pin.
    def premises_xy(xy, target, opts, log)
      xy = Geometry.clean(Geometry.counter_clockwise(xy))
      if target && !target.hull.all? { |p| inside?(xy, p) }
        log.note("widened the premises to take in the whole building")
        xy = Geometry.counter_clockwise(Geometry.convex_hull(xy + target.hull))
      end
      return xy if xy.size <= opts[:max_vertices]

      log.note("simplified #{xy.size} vertices to at most #{opts[:max_vertices]}")
      Geometry.simplify_containing(xy, opts[:max_vertices], (target ? target.hull : []) + [[0.0, 0.0]])
    end

    def inside?(xy, point)
      Geometry.contains?(xy, point) || Geometry.distance_to_edges(xy, point) < 0.01
    end

    def ring_of(xy, pin, precision)
      ring = Geometry.lnglat(xy, pin, precision)
      ring << ring.first
    end

    def failure_reason(result)
      return result.explanation.last if result.ring.nil?

      result.validation.errors.join(", ")
    end

    # Grow from the building toward its lot; trim at public roads and
    # railways (the premises never cross one) and short of neighbouring
    # buildings; then take in the site's parking, garages, canopies and
    # driveways (generator_lot.rb).
    def grow_trim(features, opts, log)
      target = find_building(features, opts, log)
      return [nil, nil] unless target

      log.note("grew the building rectangle by #{opts[:grow_m]} m")
      poly = trim_at_roads(grown(target, opts[:grow_m], opts), features, target, opts, log)
      lots, shared = own_parking(features, target, opts, log)
      return [centre(shared, Site.new(features, target, opts, log)), target] if opts[:scope] == :centre && shared.any?

      claimed = lots.select { |lot| lot.kind == "building" }
      features = features.with_buildings(features.buildings - claimed) unless claimed.empty?
      poly = trim_at_neighbours(poly, features, target, opts, log)
      poly = add_parking(poly, lots, Site.new(features, target, opts, log, shared)) unless lots.empty?
      [poly, target]
    end

    def neighbours(features, target, opts)
      features.buildings.reject { |b| b.equal?(target) || b.area < opts[:neighbour_min_area_m2] }
    end

    # The building's minimum rectangle plus a margin, trimmed at public
    # roads (premises never cross one).
    def building(features, opts, log)
      target = find_building(features, opts, log)
      return [nil, nil] unless target

      log.note("building rectangle grown by #{opts[:building_margin_m]} m")
      [trim_at_roads(grown(target, opts[:building_margin_m], opts), features, target, opts, log), target]
    end

    # The building's rectangle grown by margin metres, taking in the pin.
    def grown(target, margin, opts)
      rect = target.rectangle
      box = Geometry.oriented_box(rect[:corners], rect[:angle], margin)
      Geometry.counter_clockwise(Geometry.convex_hull(box + pin_square(opts)))
    end

    # The smallest building under the pin, else the nearest one close enough.
    # Flags a large one: the site may be one unit of it.
    def find_building(features, opts, log)
      target = building_under_pin(features, log) || nearest_building(features, opts, log)
      if target&.kind == "ml_building"
        log.flag(:ml_footprint, "building #{target.id} is a machine-learned footprint, not mapped in OSM: " \
                                "check it exists")
      end
      if target && target.area < opts[:small_building_m2]
        log.flag(:small_building, "building is only #{target.area.round} m2: check it's the site " \
                                  "(a kiosk or drive-through), not a shed or canopy next to it")
      end
      if target && target.area > opts[:large_building_m2]
        log.flag(:large_building, "building is over #{opts[:large_building_m2]} m2: if it's shared " \
                                  "(strip mall, several tenants), check which part is the site")
      elsif target && target.area > opts[:large_building_note_m2]
        log.note("building is #{target.area.round} m2: large enough that it may be shared")
      end
      target
    end

    def building_under_pin(features, log)
      target = features.buildings.select { |b| Geometry.contains?(b.xy, [0.0, 0.0]) }.min_by(&:area)
      log.note("building #{target.id} is under the pin (#{target.area.round} m2)") if target
      target
    end

    # Why no building was found, as a hint: usually it's missing from OSM,
    # which machine-learned footprints often fill.
    def missing_hint(opts)
      return "" unless opts[:buildings] == :osm

      " (it may be missing from OpenStreetMap: try buildings: :osm_filled)"
    end

    # A tiny structure (a canopy or kiosk roof) right by the pin loses to a
    # real building in reach: the canopy then counts as part of the lot.
    def nearest_building(features, opts, log)
      in_reach = features.buildings.map { |b| [Geometry.distance_to_edges(b.xy, [0.0, 0.0]), b] }
                         .select { |d, _| d <= opts[:building_max_distance_m] }
      real = in_reach.reject { |_, b| b.area < opts[:small_building_m2] }
      distance, target = (real.empty? ? in_reach : real).min_by(&:first)
      if target
        log.flag(:building_not_under_pin, "no building under the pin; using building #{target.id}, " \
                                          "#{distance.round} m away (#{target.area.round} m2)")
        target
      else
        log.note("no building within #{opts[:building_max_distance_m]} m of the pin#{missing_hint(opts)}")
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

        trimmed, used = trim_along(poly, fit_direction(run, target), target, offset,
                                   [opts[:building_clearance_m], opts[:pin_clearance_m]])
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
      (features.public_roads + features.railways)
        .flat_map { |road| road_runs(road, target).map { |run| [road, run, road_offset(road, opts)] } }
        .sort_by { |_, run, _| run.map { |p| Geometry.distance_to_edges(target.hull, p) }.min }
    end

    ROAD_REACH_M = 60   # only the road this close to the building bounds the site
    ROAD_BEND_DEG = 30  # a sharper turn starts a new stretch
    ROAD_SNAP_DEG = 10  # a stretch this close to a building side is squared to it

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
      n = [(Geometry.distance(a, b) / 2).ceil, 1].max
      (0..n).map { |i| Geometry.lerp(a, b, i.fdiv(n)) }
    end

    # Smallest angle between two undirected headings (radians, mod pi).
    def angle_between(first, second)
      d = (first - second).abs % Math::PI
      [d, Math::PI - d].min
    end

    # [centroid, unit direction] of the stretch's best-fit line, snapped to a
    # building side when nearly parallel.
    #
    # The direction is the length-weighted average of the stretch's own
    # heading (a short jog or fork barely moves it), and the line sits at the
    # median of the points across it (one side branch can't drag it).
    def fit_direction(points, target)
      heading = mean_heading(points)
      axis = target.rectangle[:angle]
      2.times do |k|
        side = axis + (k * Math::PI / 2)
        heading = side if angle_between(heading % Math::PI, side % Math::PI) <= ROAD_SNAP_DEG * Math::PI / 180
      end
      direction = [Math.cos(heading), Math.sin(heading)]
      [median_line_point(points, direction), direction]
    end

    # Average of segment headings as undirected lines (doubled angles), each
    # weighted by its length.
    def mean_heading(points)
      sum_cos = 0.0
      sum_sin = 0.0
      points.each_cons(2) do |a, b|
        length = Geometry.distance(a, b)
        angle = 2 * Math.atan2(b[1] - a[1], b[0] - a[0])
        sum_cos += length * Math.cos(angle)
        sum_sin += length * Math.sin(angle)
      end
      Math.atan2(sum_sin, sum_cos) / 2
    end

    # A point on the line with the given direction that has half the points
    # on each side.
    def median_line_point(points, direction)
      normal = [-direction[1], direction[0]]
      centre = Geometry.centroid(points)
      offsets = points.map { |p| Geometry.dot([p[0] - centre[0], p[1] - centre[1]], normal) }.sort
      median = offsets[offsets.size / 2]
      [centre[0] + (normal[0] * median), centre[1] + (normal[1] * median)]
    end

    # Clips at the line, moved toward the pin by up to offset metres but
    # never closer than clearance metres to the building (the pavement in
    # front of a building on the street stays in the premises) or to the pin
    # (a pin dropped on the pavement stays inside). clearance: [building m,
    # pin m]. Returns
    # [polygon, offset used], [poly, 0] when the pin is on the line, or nil
    # when the centreline itself would cut the building.
    def trim_along(poly, line, target, offset, clearance = [0, 0])
      origin, direction = line
      normal = [direction[1], -direction[0]]
      pin_side = side([0.0, 0.0], origin, normal)
      return [poly, 0] if pin_side.abs < 1e-6

      normal = normal.map(&:-@) if pin_side.positive?
      building_side = target.hull.map { |p| side(p, origin, normal) }.max
      return nil if building_side > 0.5

      offset = offset.clamp(0, room(building_side, pin_side, clearance))
      origin = [origin[0] - (normal[0] * offset), origin[1] - (normal[1] * offset)]
      [Geometry.clip_half_plane(poly, origin, normal), offset]
    end

    # How far toward the pin a road trim may move: short of the building and
    # of the pin by their clearances, never past the centreline.
    def room(building_side, pin_side, clearance)
      room = [-building_side - clearance[0], pin_side.abs - clearance[1]].min
      room.negative? ? 0 : room
    end

    # Half the road's width when the caller gives no fixed offset.
    def road_offset(road, opts)
      opts[:road_offset_m] || ROAD_HALF_WIDTH_M.fetch(road.highway, ROAD_HALF_WIDTH_M["link"])
    end

    def trim_at_neighbours(poly, features, target, opts, log)
      hull = target.hull
      area = Geometry.bounds(poly)
      neighbours(features, target, opts).each do |other|
        next unless Geometry.bounds_near?(area, other.bounds)

        other_hull = other.hull
        next unless Geometry.overlap?(other_hull, poly)

        if Geometry.overlap?(other_hull, hull)
          log.note("building #{other.id} touches the building, so it can't be split off")
          next
        end
        home = home?(other, features, opts) && (behind_home?(other, target, features) ? :behind : :beside)
        strip = neighbour_strip(other, home, opts)
        trimmed = split_from_neighbour(poly, hull, other_hull, target.rectangle[:angle], stop: strip_stop(strip))
        next if trimmed.size < 3

        explain_cut(log, other, home, strip)
        poly = trimmed
      end
      poly
    end

    HALFWAY = ->(near, far) { (near + far) / 2 }

    # home: :behind, :beside or false (not a home).
    def explain_cut(log, other, home, strip)
      case home
      when :behind
        log.flag(:near_houses, "the lot backs onto a home (building #{other.id}): split halfway, " \
                               "check where its yard starts")
      when :beside
        log.flag(:near_houses, "the lot runs beside a home (building #{other.id}), stopping " \
                               "#{strip} m short of it: check the property line")
      else
        log.note(strip ? "stopped #{strip} m short of building #{other.id}" : "split halfway to building #{other.id}")
      end
    end

    # The strip left to a neighbour, or nil to split halfway. Pavement
    # between two buildings usually belongs to one of them, and the site's
    # own lot is the likelier owner, so claim it up to a narrow strip.
    # Small neighbours (houses, below neighbour_strip_min_area_m2) keep the
    # halfway split: their yard isn't the site's.
    def neighbour_strip(other, home, opts)
      gap = opts[:neighbour_gap_m]
      return nil if home == :behind

      gap if gap && other.area >= opts[:neighbour_strip_min_area_m2]
    end

    # A home: typed as one, or (untyped, as mappers often leave it) a small
    # building with other small buildings close by, like a residential street.
    def home?(other, features, opts)
      return true if HOUSE_TYPES.include?(other.category)
      return false if other.category || other.area >= opts[:house_max_m2]

      small = features.buildings.count do |b|
        !b.equal?(other) && b.category.nil? && b.area < opts[:house_max_m2] && b.near?(other, opts[:house_street_m])
      end
      small >= 2
    end

    # Whether the site is behind the home: across its back yard, judged by
    # which way the home faces its nearest street. Beside or in front of a
    # home, the lot runs up to the usual strip; behind it, only halfway.
    def behind_home?(home, target, features)
      centre = Geometry.centroid(home.hull)
      street = nearest_street_point(centre, features)
      return true unless street

      front = [street[0] - centre[0], street[1] - centre[1]]
      site = Geometry.centroid(target.hull).zip(centre).map { |a, b| a - b }
      cosine = Geometry.dot(front, site) / ((Math.hypot(*front) * Math.hypot(*site)) + 1e-9)
      cosine < -0.5
    end

    def nearest_street_point(point, features)
      points = features.public_roads.flat_map do |road|
        road.xy.each_cons(2).map { |a, b| Geometry.closest_point_on_segment(point, a, b) }
      end
      points.min_by { |p| Geometry.distance(p, point) }
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
