# frozen_string_literal: true

module Curtilage
  # The OSM features around a pin, projected to metres around it.
  #
  # Input is a list of hashes (string or symbol keys) with "feature"
  # ("building", "ml_building", "parking", "road" or "railway"), "geometry"
  # (a GeoJSON geometry hash), and optionally "id", "name" and "highway"
  # (the class: road or railway class, or building type). Map data is
  # untrusted, so oversized inputs and broken geometry are dropped and
  # counted, not raised.
  class Features
    MAX_FEATURES = 20_000
    MAX_VERTICES = 5_000

    # category: the building type from OSM (house, parking, roof, ...), or nil.
    Polygon = Struct.new(:id, :kind, :name, :xy, :area, :category, keyword_init: true) do
      def hull
        @hull ||= Geometry.convex_hull(xy)
      end

      def rectangle
        @rectangle ||= Geometry.minimum_rectangle(xy)
      end

      # [min_x, min_y, max_x, max_y], for a cheap pre-check.
      def bounds
        @bounds ||= Geometry.bounds(xy)
      end

      def near?(other, margin = 0)
        Geometry.bounds_near?(bounds, other.bounds, margin)
      end
    end
    Line = Struct.new(:id, :highway, :name, :xy, keyword_init: true)

    attr_reader :pin, :buildings, :ml_buildings, :parking, :roads, :railways, :dropped

    def initialize(pin, features)
      @pin = pin
      @buildings = []
      @ml_buildings = []
      @parking = []
      @roads = []
      @railways = []
      @dropped = 0
      @seen = {}
      Array(features).first(MAX_FEATURES).each { |f| add(f) }
      @dropped += [Array(features).size - MAX_FEATURES, 0].max
    end

    # Roads that bound a site (Generator::PUBLIC_HIGHWAYS), not service
    # roads or driveways.
    def public_roads
      @public_roads ||= roads.select { |r| Generator::PUBLIC_HIGHWAYS.include?(r.highway) }
    end

    # A copy whose buildings are the given list (see Generator buildings:).
    def with_buildings(list)
      dup.tap { |copy| copy.instance_variable_set(:@buildings, list) }
    end

    private

    def add(feature)
      kind = field(feature, :feature).to_s
      # A region built from several extracts repeats OSM features along the
      # seam. ML footprints' ids are only unique within one file, so they're
      # never treated as repeats.
      id = field(feature, :id)
      if id && kind != "ml_building"
        return if @seen.key?([kind, id])

        @seen[[kind, id]] = true
      end
      geometry = field(feature, :geometry)
      parts = parts_of(geometry)
      return @dropped += 1 if parts.nil? || parts.empty?

      parts.each { |coords| add_part(feature, kind, coords) }
    end

    def add_part(feature, kind, coords)
      return @dropped += 1 unless coords.is_a?(Array) && coords.size <= MAX_VERTICES
      return @dropped += 1 unless Geometry.valid_coordinates?(coords)

      xy = Geometry.project(coords, pin)
      if %w[road railway].include?(kind)
        return @dropped += 1 if xy.size < 2

        line = Line.new(id: field(feature, :id), highway: field(feature, :highway)&.to_s,
                        name: field(feature, :name), xy: xy)
        (kind == "road" ? @roads : @railways) << line
      else
        add_polygon(feature, kind, xy)
      end
    end

    def add_polygon(feature, kind, xy)
      ring = Geometry.clean(Geometry.open_ring(xy))
      area = ring.size >= 3 ? Geometry.area(ring) : 0
      return @dropped += 1 if area < 1 || Geometry.self_intersects?(ring)

      category = field(feature, :highway).to_s
      polygon = Polygon.new(id: field(feature, :id), kind: kind, name: field(feature, :name),
                            xy: Geometry.counter_clockwise(ring), area: area,
                            category: category.empty? ? nil : category)
      case kind
      when "building" then @buildings << polygon
      when "ml_building" then @ml_buildings << polygon
      when "parking" then @parking << polygon
      else @dropped += 1
      end
    end

    # Outer rings of polygons, or the lines of line strings. Holes are
    # ignored: premises cover a building's courtyard too.
    def parts_of(geometry)
      return nil unless geometry.is_a?(Hash)

      coords = field(geometry, :coordinates)
      return nil unless coords.is_a?(Array)

      case field(geometry, :type)
      when "Polygon" then [coords.first].compact
      when "MultiPolygon" then coords.filter_map { |poly| poly.is_a?(Array) ? poly.first : nil }
      when "LineString" then [coords]
      when "MultiLineString" then coords
      end
    end

    def field(hash, key)
      hash[key.to_s] || hash[key]
    end
  end
end
