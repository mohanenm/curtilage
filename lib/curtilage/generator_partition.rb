# frozen_string_literal: true

module Curtilage
  # method: :partition (experimental; never a fallback). The ground round
  # the building is shared with every other building nearby, by the
  # shortest path that doesn't cross a public road or railway. The site
  # keeps ground up to PARTITION_SHARE times as far from its building as
  # from the nearest other one, and neighbour_gap_m clear of it: the pinned
  # building is the business, so it takes more than an even share (an even
  # split gave the site's own parking to the building next door). Reach:
  # grow_m on open ground, parking_max_extent_m on mapped parking and along
  # service roads (aisle_m either side). The premises follow the ground, so
  # they aren't convex.
  module Generator
    PARTITION_SHARE = 2

    module_function

    def partition(features, opts, log)
      target = find_building(features, opts, log) or return [nil, nil]

      grid, layers = partition_layers(features, target, opts)
      grid.set { |i| site_cell?(i, layers, opts) }
      return [nil, target] unless grid.keep_part?([0.0, 0.0])

      log.note("shared the ground round the building with #{layers[:others]} other building(s) nearby, " \
               "short of public roads and railways", step: "partition", features: [target.id])
      [Geometry.counter_clockwise(Geometry.douglas_peucker(grid.outline, grid.cell)), target]
    end

    # The site's footprint and the pin are always its; another building's
    # footprint never is; other ground goes by the two path distances.
    def site_cell?(index, layers, opts)
      return true if layers[:keep][index]
      return false if layers[:theirs][index]

      mine = layers[:to_mine][index]
      theirs = layers[:to_theirs][index]
      mine <= theirs * PARTITION_SHARE && theirs >= (opts[:neighbour_gap_m] || 0) &&
        mine <= (layers[:paved][index] ? opts[:parking_max_extent_m] : opts[:grow_m])
    end

    # The grid round the building and its layers, with the path distance
    # from the site's footprint and from the other buildings'.
    def partition_layers(features, target, opts)
      reach = [opts[:grow_m], opts[:parking_max_extent_m]].max
      grid = partition_grid(target, reach)
      layers = footprints(grid, features, target, opts)
      blocked, paved = partition_ground(grid, features, opts)
      to = %i[mine theirs].to_h { |k| [:"to_#{k}", grid.path_distance(layers[k], blocked, reach)] }
      [grid, layers.merge(paved: paved, **to)]
    end

    # The site's footprint, the other buildings' (canopies and car parks are
    # ground), and the site's footprint with the pin, which it always keeps.
    def footprints(grid, features, target, opts)
      others = neighbours(features, target, opts).reject { |o| LOT_TYPES.include?(o.category) }
      mine = grid.painted([target.xy])
      { mine: mine, theirs: grid.painted(others.map(&:xy)).each_with_index.map { |t, i| t && !mine[i] },
        keep: grid.painted([Geometry.convex_hull(target.hull + pin_square(opts))]), others: others.size }
    end

    # A metre a cell, coarser round very large buildings.
    def partition_grid(target, reach)
      b = target.bounds
      extent = [b[0] - reach, b[1] - reach, b[2] + reach, b[3] + reach]
      Grid.new(extent, ((extent[2] - extent[0]) + (extent[3] - extent[1])).fdiv(600).clamp(1, 3))
    end

    # [blocked, paved] layers: public roads and railways (half their width
    # either side) block a path; mapped parking and service-road strips are
    # paved.
    def partition_ground(grid, features, opts)
      barriers = (features.public_roads + features.railways).flat_map { |r| strips(r.xy, road_offset(r, opts)) }
      service = features.roads.reject { |r| PUBLIC_HIGHWAYS.include?(r.highway) }
      aisles = service.flat_map { |r| strips(r.xy, opts[:aisle_m]) }
      [grid.painted(barriers), grid.painted(features.parking.map(&:xy) + aisles)]
    end

    # A line as rounded strips half metres either side, one per segment.
    def strips(line, half) = line.each_cons(2).map { |a, c| grown_hull([a, c], half) }
  end
end
