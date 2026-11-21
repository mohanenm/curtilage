# frozen_string_literal: true

module Curtilage
  # The OSM features around a pin, projected to metres around it.
  #
  # Input is a list of hashes (string or symbol keys) with "feature"
  # ("building", "parking" or "road"), "geometry" (a GeoJSON geometry hash),
  # and optionally "id", "highway" and "name". OSM data is untrusted, so
  # oversized inputs and broken geometry are dropped and counted, not raised.
  class Features
    MAX_FEATURES = 20_000
    MAX_VERTICES = 5_000

    Polygon = Struct.new(:id, :kind, :name, :xy, :area, keyword_init: true) do
      def hull
        @hull ||= Geometry.convex_hull(xy)
      end
    end
    Line = Struct.new(:id, :highway, :name, :xy, keyword_init: true)

    attr_reader :pin, :buildings, :parking, :roads, :dropped

    def initialize(pin, features)
      @pin = pin
      @buildings = []
      @parking = []
      @roads = []
      @dropped = 0
      Array(features).first(MAX_FEATURES).each { |f| add(f) }
      @dropped += [Array(features).size - MAX_FEATURES, 0].max
    end

    private

    def add(feature)
      kind = field(feature, :feature).to_s
      geometry = field(feature, :geometry)
      parts = parts_of(geometry)
      return @dropped += 1 if parts.nil? || parts.empty?

      parts.each { |coords| add_part(feature, kind, coords) }
    end

    def add_part(feature, kind, coords)
      return @dropped += 1 unless coords.is_a?(Array) && coords.size <= MAX_VERTICES
      return @dropped += 1 unless Geometry.valid_coordinates?(coords)

      xy = Geometry.project(coords, pin)
      if kind == "road"
        return @dropped += 1 if xy.size < 2

        @roads << Line.new(id: field(feature, :id), highway: field(feature, :highway)&.to_s,
                           name: field(feature, :name), xy: xy)
      else
        add_polygon(feature, kind, xy)
      end
    end

    def add_polygon(feature, kind, xy)
      ring = Geometry.clean(Geometry.open_ring(xy))
      area = ring.size >= 3 ? Geometry.area(ring) : 0
      return @dropped += 1 if area < 1 || Geometry.self_intersects?(ring)

      polygon = Polygon.new(id: field(feature, :id), kind: kind, name: field(feature, :name),
                            xy: Geometry.counter_clockwise(ring), area: area)
      case kind
      when "building" then @buildings << polygon
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
