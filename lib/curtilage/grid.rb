# frozen_string_literal: true

module Curtilage
  # A raster of the plane in metres, for shapes that clipping convex
  # polygons can't make: unions and differences of polygons, gaps closed
  # between a building and its parking. Painting cells sidesteps the
  # degenerate cases of exact polygon booleans (shared edges, touching
  # corners, holes); the outline it traces is within a cell of the exact
  # one, and the checks made on that outline afterwards are exact.
  class Grid
    # Squared distance, in cells, from every cell to the nearest source cell
    # (Felzenszwalb and Huttenlocher's exact transform, by rows then
    # columns). cells: flat row-major array of true/false.
    module Distance
      FAR = 1e18 # "no source cell"

      module_function

      def squared(cells, width, height, source)
        grid = cells.map { |v| v == source ? 0.0 : FAR }
        height.times { |row| grid[row * width, width] = line(grid[row * width, width]) }
        width.times do |col|
          column = line(Array.new(height) { |row| grid[(row * width) + col] })
          column.each_with_index { |d, row| grid[(row * width) + col] = d }
        end
        grid
      end

      # The lower envelope of parabolas rooted at each cell of one line.
      def line(costs)
        roots, bounds = envelope(costs)
        k = 0
        Array.new(costs.size) do |q|
          k += 1 while bounds[k + 1] < q
          ((q - roots[k])**2) + costs[roots[k]]
        end
      end

      def envelope(costs)
        roots = Array.new(costs.size, 0)
        bounds = Array.new(costs.size + 1, 0.0)
        bounds[0] = -FAR
        bounds[1] = FAR
        k = 0
        (1...costs.size).each do |q|
          s = meet(costs, q, roots[k])
          s = meet(costs, q, roots[k -= 1]) while s <= bounds[k]
          roots[k += 1] = q
          bounds[k] = s
          bounds[k + 1] = FAR
        end
        [roots, bounds]
      end

      # Where the parabolas rooted at q and p cross.
      def meet(costs, q, p) = ((costs[q] + (q * q)) - (costs[p] + (p * p))) / (2.0 * (q - p))
    end

    # Tracing the outline of one part with no holes or corner touches.
    module Trace
      private

      # The cell's sides that face an empty cell, as [from, to] corners
      # (integer [col, row]) going counter-clockwise round the shape.
      def sides(col, row)
        i = (row * @w) + col
        out = []
        out << [[col, row], [col + 1, row]] unless row.positive? && @on[i - @w]
        out << [[col + 1, row], [col + 1, row + 1]] unless col < @w - 1 && @on[i + 1]
        out << [[col + 1, row + 1], [col, row + 1]] unless row < @h - 1 && @on[i + @w]
        out << [[col, row + 1], [col, row]] unless col.positive? && @on[i - 1]
        out
      end

      def chain(nexts)
        start = nexts.keys.min
        ring = [start]
        point = nexts[start]
        until point == start
          ring << point
          point = nexts.fetch(point)
        end
        ring
      end

      # Corner points in metres, dropping those on a straight run.
      def corners_to_metres(ring)
        n = ring.size
        kept = ring.each_index.reject { |i| Geometry.cross(ring[(i - 1) % n], ring[i], ring[(i + 1) % n]).zero? }
        kept.map { |i| [@x0 + (ring[i][0] * @cell), @y0 + (ring[i][1] * @cell)] }
      end

      # Fills both empty cells of any 2 x 2 block whose full cells touch only
      # at a corner (the outline would pinch there). True if any changed.
      def fill_corners
        changed = false
        (0...(@h - 1)).each do |row|
          (0...(@w - 1)).each do |col|
            a = (row * @w) + col
            block = [a, a + 1, a + @w, a + @w + 1]
            next unless [[true, false, false, true], [false, true, true, false]].include?(block.map { |i| @on[i] })

            block.each { |i| @on[i] = true }
            changed = true
          end
        end
        changed
      end
    end

    # Keeping the part inside some rings, and the convex outline.
    module Regions
      # Keeps only the cells inside one of the rings.
      def keep_inside(rings)
        cells = painted(rings)
        @on.each_index { |i| @on[i] &&= cells[i] }
        self
      end

      # A separate layer: true in the cells inside one of the rings.
      def painted(rings) = Array.new(@on.size, false).tap { |cells| rings.each { |xy| paint(xy, cells: cells) } }

      # Sets each cell to the block's answer for its index.
      def set(&)
        @on = Array.new(@on.size, &)
        self
      end

      # The convex outline of the shape (from each row's first and last cell),
      # in metres; [] when empty.
      def hull
        edges = (0...@h).flat_map do |row|
          line = @on[row * @w, @w]
          first = line.index(true)
          next [] unless first

          last = line.rindex(true)
          y0 = @y0 + (row * @cell)
          [[first, y0], [last + 1, y0], [first, y0 + @cell], [last + 1, y0 + @cell]]
        end
        Geometry.convex_hull(edges.map { |col, y| [@x0 + (col * @cell), y] })
      end
    end

    # Shortest paths over the cells, round blocked ones.
    module Paths
      # 8 neighbours: [column step, row step, cost in tenths of a cell].
      MOVES = [[1, 0, 10], [-1, 0, 10], [0, 1, 10], [0, -1, 10],
               [1, 1, 14], [1, -1, 14], [-1, 1, 14], [-1, -1, 14]].freeze

      # Metres from the nearest source cell to every cell, by the shortest
      # path that never enters a blocked cell (Dial's buckets); infinite
      # beyond limit metres. source, blocked: layers (see painted).
      def path_distance(source, blocked, limit)
        far = (limit / @cell * 10).ceil
        run = { dist: Array.new(@on.size, Float::INFINITY), blocked: blocked, far: far,
                buckets: Array.new(far + 15) { [] } }
        run[:buckets][0] = source.each_index.select { |i| source[i] }
        run[:buckets][0].each { |i| run[:dist][i] = 0 }
        run[:buckets].each_with_index { |bucket, d| bucket.each { |i| relax(i, d, run) if run[:dist][i] == d } }
        run[:dist].map { |d| d * @cell / 10 }
      end

      private

      # Shortens the paths to the cell's neighbours through it.
      def relax(index, dist, run)
        steps(index).each do |j, cost|
          next if run[:blocked][j] || dist + cost >= run[:dist][j] || dist + cost > run[:far]

          run[:dist][j] = dist + cost
          run[:buckets][dist + cost] << j
        end
      end

      # [neighbour index, cost] for each of the 8 neighbours inside the grid.
      def steps(index)
        col = index % @w
        row = index / @w
        MOVES.filter_map do |dc, dr, cost|
          c = col + dc
          r = row + dr
          [(r * @w) + c, cost] if c.between?(0, @w - 1) && r.between?(0, @h - 1)
        end
      end
    end

    include Trace
    include Regions
    include Paths

    attr_reader :cell

    # bounds: [min_x, min_y, max_x, max_y] in metres; pad: empty margin in
    # metres beyond them, at least the radius of any close (two cells are
    # always added, so outlines never touch the edge).
    def initialize(bounds, cell, pad: 0)
      @cell = cell.to_f
      @pad = pad
      margin = pad + (2 * @cell)
      @x0 = bounds[0] - margin
      @y0 = bounds[1] - margin
      @w = ((bounds[2] - bounds[0] + (2 * margin)) / @cell).ceil
      @h = ((bounds[3] - bounds[1] + (2 * margin)) / @cell).ceil
      @on = Array.new(@w * @h, false)
    end

    def count = @on.count(true)
    def area = count * @cell * @cell

    # Sets (or clears) every cell whose centre is inside the ring.
    def paint(xy, value: true, cells: @on)
      return self if xy.size < 3

      ys = xy.map(&:last)
      rows(ys.min, ys.max).each do |row|
        y = @y0 + ((row + 0.5) * @cell)
        crossings(xy, y).each_slice(2) do |a, b|
          cols(a, b).each { |col| cells[(row * @w) + col] = value } if b
        end
      end
      self
    end

    def erase(xy) = paint(xy, value: false)

    # Grows (positive metres) or shrinks (negative) the shape evenly.
    def buffer(metres)
      limit = (metres.abs / @cell)**2
      raise ArgumentError, "buffer(#{metres}) needs pad: #{metres.abs} or more" if metres.abs > @pad + @cell

      @on = if metres.positive? then Distance.squared(@on, @w, @h, true).map { |d| d <= limit }
            else Distance.squared(@on, @w, @h, false).map { |d| d > limit }
            end
      self
    end

    # Grows the shape by metres, then shrinks it back: gaps narrower than
    # twice that fill in, the outline elsewhere stays where it was.
    def close(metres) = metres.positive? ? buffer(metres).buffer(-metres) : self

    # Keeps only the shape joined (side to side) to the cell at point, with
    # its holes filled and no cells touching only at a corner, so it has one
    # simple outline. Returns false (and changes nothing) when that cell is
    # empty.
    def keep_part?(point)
      start = index_at(point)
      return false unless start && @on[start]

      @on = reach([start]) { |i| @on[i] }
      loop do
        @on = reach(border) { |i| !@on[i] }.map(&:!)
        break unless fill_corners
      end
      true
    end

    # The outline, counter-clockwise, as an open ring of cell corners in
    # metres with straight runs merged. Call keep_part? first.
    def outline
      nexts = {}
      @on.each_index do |i|
        sides(i % @w, i / @w).each { |from, to| nexts[from] = to } if @on[i]
      end
      nexts.empty? ? [] : corners_to_metres(chain(nexts))
    end

    private

    def index_at(point)
      col = ((point[0] - @x0) / @cell).floor
      row = ((point[1] - @y0) / @cell).floor
      col.between?(0, @w - 1) && row.between?(0, @h - 1) ? (row * @w) + col : nil
    end

    def rows(y_min, y_max) = [((y_min - @y0) / @cell).floor, 0].max..[((y_max - @y0) / @cell).ceil, @h - 1].min

    # Columns whose centres lie in [x_a, x_b).
    def cols(x_a, x_b)
      first = [((x_a - @x0) / @cell) - 0.5, 0].max.ceil
      last = [((x_b - @x0) / @cell) - 0.5, @w].min.ceil - 1
      first..last
    end

    def crossings(xy, y)
      xy.each_index.filter_map do |i|
        x1, y1 = xy[i]
        x2, y2 = xy[(i + 1) % xy.size]
        x1 + ((x2 - x1) * (y - y1) / (y2 - y1)) if (y1 > y) != (y2 > y)
      end.sort
    end

    # Cells reachable side to side from starts through cells the block
    # accepts.
    def reach(starts, &)
      seen = Array.new(@on.size, false)
      stack = starts.select(&)
      stack.each { |i| seen[i] = true }
      until stack.empty?
        neighbours(stack.pop).each do |j|
          next if seen[j] || !yield(j)

          seen[j] = true
          stack << j
        end
      end
      seen
    end

    def neighbours(index)
      out = []
      out << (index - 1) if (index % @w).positive?
      out << (index + 1) if index % @w < @w - 1
      out << (index - @w) if index >= @w
      out << (index + @w) if index < @on.size - @w
      out
    end

    def border
      (0...@w).flat_map { |col| [col, ((@h - 1) * @w) + col] } +
        (0...@h).flat_map { |row| [row * @w, (row * @w) + @w - 1] }
    end
  end
end
