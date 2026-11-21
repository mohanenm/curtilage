# frozen_string_literal: true

require "fileutils"

module Curtilage
  # Optional machine-learned building footprints, for places OSM hasn't
  # mapped. They are derived from imagery by ML, so they're opt-in: the build
  # adds them only with ml_footprints:, and generation uses them only with
  # buildings: :osm_filled or :ml.
  module Footprints
    class Error < StandardError; end

    SOURCES = %w[microsoft].freeze

    # Microsoft Global ML Building Footprints (ODbL, like OSM), published as
    # gzipped GeoJSON lines in zoom-9 quadkey tiles.
    MICROSOFT_HOST = "minedbuildings.z5.web.core.windows.net"
    MICROSOFT_INDEX = "/global-buildings/dataset-links.csv"
    MICROSOFT_PREFIX = "/global-buildings/"
    ZOOM = 9
    MAX_INDEX_BYTES = 50_000_000
    MAX_TILE_BYTES = 500_000_000
    MAX_TILES = 2_000

    module_function

    # Downloads the tiles covering bbox [min_lng, min_lat, max_lng, max_lat]
    # into dir and returns their paths.
    def microsoft(bbox, dir, log: $stderr)
      keys = quadkeys(bbox, ZOOM)
      rows = microsoft_index.select { |row| keys.include?(row[:quadkey]) }
      raise Error, "#{rows.size} footprint tiles is more than #{MAX_TILES}" if rows.size > MAX_TILES

      FileUtils.mkdir_p(dir)
      log.puts "downloading #{rows.size} Microsoft footprint tiles"
      rows.map do |row|
        dest = File.join(dir, "#{row[:location]}-#{row[:quadkey]}-#{File.basename(row[:path])}")
        File.file?(dest) ? dest : Download.fetch(MICROSOFT_HOST, row[:path], dest, max_bytes: MAX_TILE_BYTES)
      end
    end

    # [{location:, quadkey:, path:}] from Microsoft's index. URLs pointing
    # anywhere but Microsoft's footprint host are dropped.
    def microsoft_index
      csv = Download.read(MICROSOFT_HOST, MICROSOFT_INDEX, max_bytes: MAX_INDEX_BYTES)
      parse_index(csv)
    end

    def parse_index(csv)
      csv.each_line.drop(1).filter_map do |line|
        location, quadkey, url = line.strip.split(",")
        path = Download.path_on(url.to_s, MICROSOFT_HOST, MICROSOFT_PREFIX)
        next unless path && location.to_s.match?(/\A[\w-]+\z/) && quadkey.to_s.match?(/\A[0-3]+\z/)

        { location: location, quadkey: quadkey, path: path }
      end
    end

    # Quadkeys of the web-map tiles at zoom covering the bounding box.
    def quadkeys(bbox, zoom)
      min_lng, min_lat, max_lng, max_lat = bbox
      x0, y1 = tile(min_lng, min_lat, zoom)
      x1, y0 = tile(max_lng, max_lat, zoom)
      (x0..x1).flat_map { |x| (y0..y1).map { |y| quadkey(x, y, zoom) } }
    end

    def tile(lng, lat, zoom)
      n = 2**zoom
      lat = lat.clamp(-85.05, 85.05) * Math::PI / 180
      x = ((lng + 180) / 360 * n).floor.clamp(0, n - 1)
      y = ((1 - (Math.log(Math.tan(lat) + (1 / Math.cos(lat))) / Math::PI)) / 2 * n).floor.clamp(0, n - 1)
      [x, y]
    end

    def quadkey(x, y, zoom)
      (1..zoom).map do |i|
        mask = 1 << (zoom - i)
        (x.nobits?(mask) ? 0 : 1) + (y.nobits?(mask) ? 0 : 2)
      end.join
    end
  end
end
