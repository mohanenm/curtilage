# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

module Curtilage
  # Features straight from Overture Maps' public GeoParquet release, read in
  # place: nothing is downloaded up front and nothing has to be hosted.
  # Overture's file index (a small GeoParquet listing every file's extent)
  # narrows each pin to the one or two files covering it.
  #
  # Buildings Overture took from OpenStreetMap come back as "building"; its
  # other sources (machine-learned footprints and others) as "ml_building",
  # used only with buildings: :osm_filled or :ml. Each query tells the
  # storage host roughly which area is being read.
  module Overture
    class Error < StandardError; end

    STAC_HOST = "stac.overturemaps.org"
    CATALOG = "/catalog.json"
    MAX_INDEX_BYTES = 20_000_000
    MAX_OUTPUT_BYTES = 200_000_000
    ROAD_CLASSES = %w[motorway trunk primary secondary tertiary unclassified residential service].freeze
    RAIL_CLASSES = { "standard_gauge" => "rail", "light_rail" => "light_rail", "subway" => "subway",
                     "narrow_gauge" => "narrow_gauge" }.freeze
    COLLECTIONS = %w[building segment infrastructure].freeze
    ATTRIBUTION = ["© OpenStreetMap contributors", "© Overture Maps Foundation"].freeze

    module_function

    # A list of feature lists, in pin order. options: duckdb:,
    # extension_directory:, radius_deg:, release: (default: the latest).
    def features_many(pins, **options)
      radius = Float(options.fetch(:radius_deg, Lookup::DEFAULT_RADIUS_DEG))
      boxes = pins.map { |pin| box(pin, radius) }
      Dir.mktmpdir("curtilage-overture") do |dir|
        index = File.join(dir, "index.parquet")
        File.binwrite(index, Download.read(STAC_HOST, "/#{release(options)}/collections.parquet",
                                           max_bytes: MAX_INDEX_BYTES))
        files = files_for(index, boxes, options)
        rows = run(data_sql(boxes, files, options), options)
        group(rows, pins.size)
      end
    end

    def release(options)
      return options[:release] if options[:release]

      latest = JSON.parse(Download.read(STAC_HOST, CATALOG, max_bytes: 1_000_000))["latest"].to_s
      raise Error, "no latest Overture release in the catalog" unless latest.match?(/\A[\d.-]+\z/)

      latest
    end

    def box(pin, radius)
      lng = Float(pin[0])
      lat = Float(pin[1])
      raise ArgumentError, "pin out of range: #{pin.inspect}" unless lng.abs <= 180 && lat.abs <= 90

      [lng - radius, lat - radius, lng + radius, lat + radius]
    end

    # {[pin_index, collection] => [s3 urls]} from the local index file.
    def files_for(index, boxes, options)
      selects = boxes.each_with_index.map do |(x0, y0, x1, y1), i|
        "SELECT #{i} AS pin_index, collection, assets.aws.alternate.s3.href AS href " \
          "FROM read_parquet(#{quote(index)}) WHERE collection IN (#{COLLECTIONS.map { |c| quote(c) }.join(", ")}) " \
          "AND bbox.xmin <= #{x1} AND bbox.xmax >= #{x0} AND bbox.ymin <= #{y1} AND bbox.ymax >= #{y0}"
      end
      rows = run([setup(options, remote: false), "#{selects.join(" UNION ALL ")};"].join("\n"), options)
      rows.group_by { |r| [r["pin_index"], r["collection"]] }.transform_values do |list|
        list.map { |r| r["href"] }.select { |h| h.to_s.start_with?("s3://overturemaps-") }
      end
    end

    def data_sql(boxes, files, options)
      scans = boxes.each_with_index.flat_map do |b, i|
        [buildings(i, b, files[[i, "building"]]), segments(i, b, files[[i, "segment"]]),
         parking(i, b, files[[i, "infrastructure"]])].compact
      end
      return "SELECT 1 WHERE false;" if scans.empty?

      [setup(options, remote: true), "#{scans.join(" UNION ALL ")};"].join("\n")
    end

    def buildings(index, bbox, files)
      return nil if files.to_a.empty?

      scan(index, files, bbox, <<~SQL)
        id, CASE WHEN sources[1].dataset = 'OpenStreetMap' THEN 'building' ELSE 'ml_building' END AS feature,
        class AS highway, names."primary" AS name, ST_AsGeoJSON(geometry)::VARCHAR AS geometry
      SQL
        .then { |sql| "#{sql} AND NOT coalesce(is_underground, false)" }
    end

    # Roads and railways at ground level (no tunnel or bridge flags).
    def segments(index, bbox, files)
      return nil if files.to_a.empty?

      rail = RAIL_CLASSES.map { |k, v| "WHEN #{quote(k)} THEN #{quote(v)}" }.join(" ")
      scan(index, files, bbox, <<~SQL)
        id, CASE subtype WHEN 'road' THEN 'road' ELSE 'railway' END AS feature,
        CASE WHEN subtype = 'rail' THEN (CASE class #{rail} END)
             WHEN subclass = 'link' THEN class || '_link' ELSE class END AS highway,
        names."primary" AS name, ST_AsGeoJSON(geometry)::VARCHAR AS geometry
      SQL
        .then do |sql|
          "#{sql} AND ((subtype = 'road' AND class IN (#{ROAD_CLASSES.map { |c| quote(c) }.join(", ")})) " \
            "OR (subtype = 'rail' AND class IN (#{RAIL_CLASSES.keys.map { |c| quote(c) }.join(", ")}))) " \
            "AND NOT list_has_any(flatten(list_transform(coalesce(road_flags, []) || coalesce(rail_flags, []), " \
            "f -> f.\"values\")), ['is_tunnel', 'is_bridge'])"
        end
    end

    def parking(index, bbox, files)
      return nil if files.to_a.empty?

      scan(index, files, bbox, <<~SQL)
        id, 'parking' AS feature, NULL AS highway, names."primary" AS name,
        ST_AsGeoJSON(geometry)::VARCHAR AS geometry
      SQL
        .then do |sql|
          "#{sql} AND subtype = 'transit' AND class = 'parking' " \
            "AND ST_GeometryType(geometry) IN ('POLYGON', 'MULTIPOLYGON')"
        end
    end

    def scan(index, files, bbox, columns)
      x0, y0, x1, y1 = bbox
      "SELECT #{index} AS pin_index, #{columns.tr("\n", " ")} " \
        "FROM read_parquet([#{files.map { |f| quote(f) }.join(", ")}]) " \
        "WHERE bbox.xmin <= #{x1} AND bbox.xmax >= #{x0} AND bbox.ymin <= #{y1} AND bbox.ymax >= #{y0}"
    end

    def setup(options, remote:)
      ext = options[:extension_directory]
      [("SET extension_directory = #{quote(File.expand_path(ext))};" if ext), "LOAD spatial;",
       # Pins in the same files share one read of each file's metadata.
       (if remote
          "LOAD httpfs; SET s3_region = 'us-west-2'; SET parquet_metadata_cache = true; " \
            "SET enable_http_metadata_cache = true;"
        end)].compact.join("\n")
    end

    def run(sql, options)
      out, err, status = Open3.capture3(options.fetch(:duckdb, "duckdb"), "-json", stdin_data: sql)
      raise Error, "duckdb failed: #{err.strip[0, 500]}" unless status.success?
      raise Error, "duckdb output too large" if out.bytesize > MAX_OUTPUT_BYTES

      out.strip.empty? ? [] : JSON.parse(out)
    end

    def group(rows, count)
      lists = Array.new(count) { [] }
      rows.each do |row|
        index = row.delete("pin_index")
        lists[index] << row.merge("geometry" => JSON.parse(row["geometry"])) if index.is_a?(Integer)
      end
      lists
    end

    def quote(text)
      "'#{text.to_s.gsub("'", "''")}'"
    end
  end
end
