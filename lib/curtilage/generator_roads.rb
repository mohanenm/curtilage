# frozen_string_literal: true

module Curtilage
  # Where public roads and railways run beside the building, as stretches
  # to trim along (see trim_at_roads). Split from generator.rb only to keep
  # files a readable size.
  module Generator
    ROAD_REACH_M = 60   # only the road this close to the building bounds the site
    ROAD_BEND_DEG = 30  # a sharper turn starts a new stretch
    ROAD_SNAP_DEG = 10  # a stretch this close to a building side is squared to it
    ROAD_INSIDE_M = 5   # this much public road centreline inside the premises raises crosses_road

    module_function

    # [road, stretch points, offset] for every public road and railway near
    # the building, nearest stretch first.
    def road_stretches(features, target, opts)
      (features.public_roads + features.railways)
        .flat_map { |road| road_runs(road, target).map { |run| [road, run, road_offset(road, opts)] } }
        .sort_by { |_, run, _| run.map { |p| Geometry.distance_to_edges(target.hull, p) }.min }
    end

    # Premises should stop at public roads, but a pin on or across the road
    # from its building keeps both sides (trim_at_roads): flag any premises
    # holding ROAD_INSIDE_M or more of a public road's centreline, counted
    # 1 m in from their edge so a road along the boundary doesn't count.
    def flag_crosses_road(premises, features, log)
      inside = features.public_roads.select do |road|
        road.xy.each_cons(2).sum { |a, b| Audit.inside_length(premises, a, b) } >= ROAD_INSIDE_M
      end
      return if inside.empty?

      log.flag(:crosses_road, "the premises cross #{inside.map { |r| road_label(r) }.join(", ")}: they should stop " \
                              "at it; check the pin is on the business's side", step: "check_premises",
                                                                                features: inside.map(&:id))
    end

    # Points every 2 m along the road within reach of the building, split
    # into stretches wherever the road turns by more than ROAD_BEND_DEG.
    #
    # A segment whose box is more than ROAD_REACH_M from the building's box
    # has no point in reach, so it's skipped unsampled: most roads in the
    # map data around a pin are far from the building.
    def road_runs(road, target)
      runs = []
      run = nil
      road.xy.each_cons(2) do |a, b|
        run = segment_in_reach?(a, b, target) ? extend_runs(runs, run, a, b, target) : nil
      end
      runs.map { |r| r[:points] }.select { |pts| pts.size >= 2 }
    end

    def segment_in_reach?(first, last, target)
      Geometry.bounds_near?(Geometry.bounds([first, last]), target.bounds, ROAD_REACH_M)
    end

    # Adds the segment a-b's points in reach to the stretch going on, or to
    # a new one after a gap or a sharp turn; returns the stretch going on.
    def extend_runs(runs, run, a, b, target)
      heading = Math.atan2(b[1] - a[1], b[0] - a[0]) % Math::PI
      samples(a, b).each do |p|
        next run = nil if Geometry.distance_to_edges(target.hull, p) > ROAD_REACH_M

        if run.nil? || angle_between(run[:heading], heading) > ROAD_BEND_DEG * Math::PI / 180
          run = { heading: heading, points: [] }
          runs << run
        end
        run[:points] << p
      end
      run
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
  end
end
