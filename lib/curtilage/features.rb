# frozen_string_literal: true

require "digest"
require "json"

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
    # Parcels are cut to this square round the pin (m): a tract can run for km.
    PARCEL_WINDOW = [[-500, -500], [500, -500], [500, 500], [-500, 500]].freeze

    # category: the building type from OSM (house, parking, roof, ...), or nil.
    # source: where a non-OSM building came from (Overture's dataset name).
    Polygon = Struct.new(:id, :kind, :name, :xy, :area, :category, :source, keyword_init: true) do
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

    # parcels: property lines the caller supplied ("parcel" features; see
    # Generator, which clips the premises to the building's parcel).
    attr_reader :pin, :buildings, :ml_buildings, :parking, :roads, :railways, :parcels, :dropped, :sha256

    # [[canonical JSON, feature], ...] sorted by the JSON: one order whatever
    # order the features came in (DuckDB promises none), so the rules see the
    # same input every time.
    def self.in_order(features)
      Array(features).map { |f| [JSON.generate(canonical(f), allow_nan: true), f] }.sort_by(&:first)
    end

    def self.canonical(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, canonical(v)] }.sort.to_h
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    def initialize(pin, features)
      @pin = pin
      @buildings = []
      @ml_buildings = []
      @parking = []
      @roads = []
      @railways = []
      @parcels = []
      @dropped = 0
      @seen = {}
      ordered = self.class.in_order(features)
      @sha256 = Digest::SHA256.hexdigest(ordered.map(&:first).join("\n"))
      ordered.first(MAX_FEATURES).each { |pair| add(pair.last) }
      @dropped += [ordered.size - MAX_FEATURES, 0].max
    end

    # Roads that bound a site (Generator::PUBLIC_HIGHWAYS), not service
    # roads or driveways.
    def public_roads
      @public_roads ||= roads.select { |r| Generator::PUBLIC_HIGHWAYS.include?(r.highway) }
    end

    # A copy centred on another point (metres, in this copy's frame): the
    # pin moves there and every feature shifts with it. A flat shift, exact
    # to well under a metre over the tens of metres a pin is snapped.
    def moved_to(point)
      dx, dy = point
      copy = dup
      copy.instance_variable_set(:@pin, Geometry.lnglat([point], pin, 9).first)
      copy.instance_variable_set(:@public_roads, nil)
      %i[@buildings @ml_buildings @parking @roads @railways @parcels].each do |name|
        list = instance_variable_get(name).map { |f| f.class.new(**f.to_h, xy: f.xy.map { |x, y| [x - dx, y - dy] }) }
        copy.instance_variable_set(name, list)
      end
      copy
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
      xy = Geometry.clip_convex(Geometry.counter_clockwise(Geometry.open_ring(xy)), PARCEL_WINDOW) if kind == "parcel"
      ring = Geometry.clean(Geometry.open_ring(xy))
      area = ring.size >= 3 ? Geometry.area(ring) : 0
      return @dropped += 1 if area < 1 || Geometry.self_intersects?(ring)

      polygon = Polygon.new(id: field(feature, :id), kind: kind, name: field(feature, :name),
                            xy: Geometry.counter_clockwise(ring), area: area, source: field(feature, :source),
                            category: field(feature, :highway).to_s.then { |c| c.empty? ? nil : c })
      case kind
      when "building" then @buildings << polygon
      when "ml_building" then @ml_buildings << polygon
      when "parking" then @parking << polygon
      when "parcel" then @parcels << polygon
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
