# frozen_string_literal: true

module Curtilage
  # entrances: :all. The default lot takes in a driveway only where it
  # leaves the lot within ENTRANCE_REACH_M of it, so a big lot's far
  # entrances, and driveways that wind, are left out. This follows the
  # mapped service roads from the lot to every place they meet a public
  # road (up to ENTRANCE_PATH_M along them) and adds a corridor along each,
  # up to the kerb. The walk runs at most ALONG_STREET_M within
  # ALONGSIDE_M of a public road, so it doesn't follow a frontage road
  # serving the whole block to its far end. The premises then aren't
  # convex: a hull round a far entrance would sweep over the neighbours.
  module Generator
    ENTRANCES = %i[near all].freeze
    ENTRANCE_PATH_M = 250 # follow driveways at most this far from the lot
    DRIVEWAY_HALF_M = 4   # a corridor is this wide each side of the driveway
    JUNCTION_M = 2.5      # service roads this close are joined
    MOUTH_APART_M = 25    # mouths closer than this are one entrance
    STEP_M = 2            # driveways are followed in steps of about this
    ALONG_STREET_M = 30   # a walk runs at most this far alongside a street,
    ALONGSIDE_M = 30      # ... that is, this close to one

    module_function

    # The lot plus a corridor to each entrance not already in it, or the lot
    # unchanged when there is none.
    def add_all_entrances(poly, site)
      found = entrance_paths(poly, site).reject do |path, _|
        Geometry.contains?(poly, path.last) || Geometry.distance_to_edges(poly, path.last) < 1
      end
      return poly if found.empty?

      paths = found.map(&:first)
      xy = corridors_xy(poly, paths, site)
      return poly unless xy

      found.each { |path, street| site.log.access_point(path.last, street, nil) }
      site.log.note("took in #{paths.size} more entrance(s) along driveways, up to #{ENTRANCE_PATH_M} m " \
                    "from the lot: premises #{m2(poly)} m2 to #{m2(xy)} m2",
                    step: "take_entrance", rule: "entrances", distance_m: ENTRANCE_PATH_M, area_before_m2: m2(poly),
                    area_after_m2: m2(xy))
      xy
    end

    # [path, street] for each entrance: the path runs from the lot along
    # service roads to the kerb of that street.
    def entrance_paths(poly, site)
      points, links = driveway_graph(site.features)
      index = street_index(site.features, ALONGSIDE_M)
      beside = points.map { |p| street_near(index, p, ALONGSIDE_M) }
      street = beside.map { |b| b if b && b[2] <= ENTRANCE_MAX_M }
      starts = points.each_index.select { |i| Geometry.contains?(poly, points[i]) }
      before = walk(starts, links, (ENTRANCE_PATH_M / STEP_M).ceil, beside)
      mouths(points, before, street, site).map do |i, road, kerb|
        path = [points[i]]
        path << points[i = before[i]] while before[i] != i
        [path.reverse << kerb, road]
      end
    end

    # Public road segments by size-metre square, each in every square within
    # size metres of it.
    def street_index(features, size)
      index = Hash.new { |h, k| h[k] = [] }
      features.public_roads.each do |road|
        road.xy.each_cons(2) do |a, b|
          x0, y0, x1, y1 = Geometry.bounds([a, b]).map { |v| v / size }
          ((x0 - 1).floor..(x1 + 1).floor).each do |cx|
            ((y0 - 1).floor..(y1 + 1).floor).each { |cy| index[[cx, cy]] << [road, a, b] }
          end
        end
      end
      index
    end

    # [road, its nearest point, distance] for the nearest public road within
    # size metres of point (the index's square size), or nil.
    def street_near(index, point, size)
      key = point.map { |v| (v / size).floor }
      best = index.fetch(key, []).map do |road, a, b|
        q = Geometry.closest_point_on_segment(point, a, b)
        [road, q, Geometry.distance(point, q)]
      end.min_by(&:last)
      best && best[2] <= size ? best : nil
    end

    # Points every STEP_M along the service roads, and which points join:
    # neighbours along a road, and points of different roads within
    # JUNCTION_M (found through a hash of JUNCTION_M squares).
    def driveway_graph(features)
      points = []
      links = []
      features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }.each do |road|
        first = points.size
        road.xy.each_cons(2) { |a, b| points.concat(samples(a, b).drop(points.size > first ? 1 : 0)) }
        (first...(points.size - 1)).each { |i| link(links, i, i + 1) }
      end
      join_junctions(points, links)
      [points, links]
    end

    def link(links, from, dest)
      (links[from] ||= []) << dest
      (links[dest] ||= []) << from
    end

    # Each point is joined to the earlier ones near it (bar the one before
    # it on its road, already joined), then filed under its square.
    def join_junctions(points, links)
      cells = Hash.new { |h, k| h[k] = [] }
      points.each_with_index do |p, i|
        cx, cy = p.map { |v| (v / JUNCTION_M).floor }
        [-1, 0, 1].product([-1, 0, 1]).each do |dx, dy|
          cells[[cx + dx, cy + dy]].each do |j|
            link(links, i, j) if j < i - 1 && Geometry.distance(p, points[j]) <= JUNCTION_M
          end
        end
        cells[[cx, cy]] << i
      end
    end

    # Breadth first from the starts, at most steps out, and at most
    # ALONG_STREET_M at a time beside a street: { point => the point it was
    # reached from } (a start maps to itself).
    def walk(starts, links, steps, beside)
      before = starts.to_h { |i| [i, i] }
      along = starts.to_h { |i| [i, 0] }
      frontier = starts
      steps.times do
        frontier = frontier.flat_map do |i|
          (links[i] || []).reject { |j| before.key?(j) }.each do |j|
            before[j] = i
            along[j] = beside[j] ? along[i] + STEP_M : 0
          end
        end
        frontier.reject! { |i| along[i] > ALONG_STREET_M }
        break if frontier.empty?
      end
      before
    end

    # [point, street, kerb point] for each place the reached driveways meet
    # a public road: the reached point nearest the street within
    # ENTRANCE_MAX_M, one per MOUTH_APART_M.
    def mouths(points, before, street, site)
      near = before.keys.filter_map { |i| [i, *street[i]] if street[i] }
      chosen = []
      near.sort_by(&:last).each do |i, street, q, _|
        next if chosen.any? { |j, *| Geometry.distance(points[i], points[j]) < MOUTH_APART_M }

        chosen << [i, street, kerb_point(points[i], q, road_offset(street, site.opts))]
      end
      chosen
    end

    # Where the line from the driveway point to the street meets the kerb
    # (offset metres short of the centreline).
    def kerb_point(point, street_point, offset)
      d = Geometry.distance(point, street_point)
      return point if d <= offset

      Geometry.lerp(street_point, point, offset / d)
    end

    # The lot and the corridors on a Grid: corridors are kept off public
    # roads (half a road width each side of the centreline), railways and
    # neighbouring buildings (1 m); the lot, building and pin go on top
    # unchanged. The outline round the pin, straightened to within a cell.
    def corridors_xy(poly, paths, site)
      strips = paths.flat_map { |path| path.each_cons(2).filter_map { |a, b| strip(a, b, DRIVEWAY_HALF_M) } }
      extent = Geometry.bounds(poly + paths.flatten(1))
      cell = corridor_cell(extent)
      grid = Grid.new(extent, cell, pad: DRIVEWAY_HALF_M)
      strips.each { |s| grid.paint(s) }
      keep_off(grid, extent, site)
      [poly, Geometry.round_buffer(site.target.hull, cell + 0.2), pin_square(site.opts)].each { |xy| grid.paint(xy) }
      return nil unless grid.keep_part?([0.0, 0.0])

      Geometry.counter_clockwise(Geometry.douglas_peucker(grid.outline, cell))
    end

    # Half a metre, up to a metre for corridors spanning 400 m each way.
    def corridor_cell(extent) = ((extent[2] - extent[0]) + (extent[3] - extent[1])).fdiv(800).clamp(0.5, 1.0)

    def keep_off(grid, extent, site)
      (site.features.public_roads + site.features.railways).each do |road|
        half = road_offset(road, site.opts)
        road.xy.each_cons(2) do |a, b|
          next unless Geometry.bounds_near?(Geometry.bounds([a, b]), extent, half)

          s = strip(a, b, half)
          grid.erase(s) if s
        end
      end
      neighbours(site.features, site.target, site.opts).each do |other|
        grid.erase(Geometry.round_buffer(other.hull, 1)) if Geometry.bounds_near?(other.bounds, extent, 1)
      end
    end

    # The rectangle half metres each side of a-b, ends squared off half
    # metres beyond them; nil for a zero-length segment.
    def strip(a, b, half)
      length = Geometry.distance(a, b)
      return nil if length < 1e-6

      along = [(b[0] - a[0]) / length * half, (b[1] - a[1]) / length * half]
      across = [-along[1], along[0]]
      [[a, -1, -1], [b, 1, -1], [b, 1, 1], [a, -1, 1]].map do |p, s, t|
        [p[0] + (s * along[0]) + (t * across[0]), p[1] + (s * along[1]) + (t * across[1])]
      end
    end
  end
end
