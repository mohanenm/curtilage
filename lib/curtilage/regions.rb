# frozen_string_literal: true

require "json"

module Curtilage
  # Geofabrik's region index (outlines plus download links), used to find
  # which region a pin is in without any prebuilt data. Only regions offered
  # as shapefiles count; where regions nest, the smallest wins (California
  # resolves to norcal or socal).
  class Regions
    HOST = "download.geofabrik.de"
    INDEX = "/index-v1.json"
    MAX_INDEX_BYTES = 50_000_000

    Region = Struct.new(:id, :path, :bbox, :rings, :extent_area, keyword_init: true) do
      def covers?(point) = Geometry.in_rings?(point, bbox, rings)
    end

    def self.download
      parse(Download.read(HOST, INDEX, max_bytes: MAX_INDEX_BYTES) { |body| JSON.parse(body) })
    end

    def self.parse(json)
      features = JSON.parse(json).fetch("features")
      new(features.filter_map { |f| region(f) })
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError => e
      raise Error, "unreadable Geofabrik region index: #{e.message[0, 200]}"
    end

    def self.region(feature)
      props = feature["properties"] || {}
      path = path_from_url(props.dig("urls", "shp"))
      rings = outer_rings(feature["geometry"])
      return nil unless path && !rings.empty?

      bbox = Geometry.bounds(rings.flatten(1))
      Region.new(id: props["id"], path: path, bbox: bbox, rings: rings,
                 extent_area: (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]))
    end

    # ".../north-america/us/tennessee/tennessee-latest-free.shp.zip" ->
    # "north-america/us/tennessee", the path Build takes.
    def self.path_from_url(url)
      path = Download.path_on(url.to_s, HOST, "/")
      match = path&.match(%r{\A/((?:[a-z0-9-]+/)*?)([a-z0-9-]+)-latest-free\.shp\.zip\z})
      return nil unless match

      dirs = match[1].split("/")
      dirs.pop if dirs.last == match[2]
      (dirs + [match[2]]).join("/")
    end

    def self.outer_rings(geometry)
      case geometry&.dig("type")
      when "Polygon" then [geometry["coordinates"].first].compact
      when "MultiPolygon" then geometry["coordinates"].filter_map(&:first)
      else []
      end
    end

    attr_reader :regions

    def initialize(regions)
      @regions = regions
    end

    # The smallest region containing the point, or nil.
    def for(point)
      @regions.select { |r| r.covers?(point) }.min_by(&:extent_area)
    end

    # Regions holding any part of the box around the pin: one, or two near a
    # border.
    def around(pin, margin)
      Geometry.box_points(pin, margin).filter_map { |c| self.for(c) }.uniq(&:path)
    end
  end
end
