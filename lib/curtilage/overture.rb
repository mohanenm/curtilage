# frozen_string_literal: true

require "json"
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
    class Error < Curtilage::Error; end

    STAC_HOST = "stac.overturemaps.org"
    CATALOG = "/catalog.json"
    MAX_INDEX_BYTES = 20_000_000
    MAX_OUTPUT_BYTES = 200_000_000
    ROAD_CLASSES = %w[motorway trunk primary secondary tertiary unclassified residential service].freeze
    RAIL_CLASSES = { "standard_gauge" => "rail", "light_rail" => "light_rail", "subway" => "subway",
                     "narrow_gauge" => "narrow_gauge" }.freeze
    COLLECTIONS = %w[building segment infrastructure].freeze
    GROUP_CELL_DEG = 0.05
    ATTRIBUTION = ["© OpenStreetMap contributors", "© Overture Maps Foundation"].freeze

    module_function

    # A list of feature lists, in pin order. options: duckdb:,
    # extension_directory:, radius_deg:, release: (default: the latest).
    def features_many(pins, **options)
      options = Curtilage.duckdb_options(options)
      radius = Float(options.fetch(:radius_deg, Lookup::DEFAULT_RADIUS_DEG))
      boxes = pins.map { |pin| box(pin, radius) }
      Dir.mktmpdir("curtilage-overture") do |dir|
        index = File.join(dir, "index.parquet")
        File.binwrite(index, Download.read(STAC_HOST, "/#{release(options)}/collections.parquet",
                                           max_bytes: MAX_INDEX_BYTES))
        boxes.each_slice(Lookup::PINS_PER_CALL).flat_map do |batch|
          rows = run(data_sql(batch, files_for(index, batch, options), options), options)
          Lookup.group_rows(rows, batch.size)
        end
      end
    end

    RELEASE = /\A\d{4}-\d{2}-\d{2}(\.\d+)?\z/

    def release(options)
      if options[:release]
        raise ArgumentError, "an Overture release looks like 2026-11-18.0: #{options[:release].inspect}" \
          unless options[:release].to_s.match?(RELEASE)

        return options[:release].to_s
      end

      latest = JSON.parse(Download.read(STAC_HOST, CATALOG, max_bytes: 1_000_000))["latest"].to_s
      raise Error, "no latest Overture release in the catalog" unless latest.match?(RELEASE)

      latest
    end

    def box(pin, radius)
      lng, lat = Lookup.checked(pin)
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

    # One scan per collection and set of files, shared by every pin those
    # files cover: each file's metadata and row groups are read once, then
    # rows are matched back to the pins whose boxes they fall in.
    def data_sql(boxes, files, options)
      scans = COLLECTIONS.flat_map do |collection|
        groups = boxes.each_index.group_by { |i| [files[[i, collection]].to_a.sort, cell(boxes[i])] }
        groups.filter_map do |(list, _), indexes|
          grouped_scan(collection, list, indexes, boxes) unless list.empty?
        end
      end
      return "SELECT 1 WHERE false;" if scans.empty?

      [setup(options, remote: true), boxes_table(boxes), "#{scans.join(" UNION ALL ")};"].join("\n")
    end

    def boxes_table(boxes)
      rows = boxes.each_with_index.map { |(x0, y0, x1, y1), i| "(#{i}, #{x0}, #{y0}, #{x1}, #{y1})" }
      "CREATE TEMP TABLE boxes (pin_index INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE); " \
        "INSERT INTO boxes VALUES #{rows.join(", ")};"
    end

    # Pins are grouped within a 0.05 degree cell (about 5 km), so a group's
    # envelope stays small.
    def cell(box)
      [(box[0] / GROUP_CELL_DEG).floor, (box[1] / GROUP_CELL_DEG).floor]
    end

    # The envelope is a plain range DuckDB can skip row groups with; the OR
    # of the pins' own boxes then drops what's between them.
    def grouped_scan(collection, files, indexes, boxes)
      group = indexes.map { |i| boxes[i] }
      envelope = [group.map { |b| b[0] }.min, group.map { |b| b[1] }.min, group.map { |b| b[2] }.max,
                  group.map { |b| b[3] }.max]
      any = group.map { |b| "(#{box_filter("bbox", b)})" }.join(" OR ")
      "SELECT p.pin_index, d.id, d.feature, d.highway, d.name, d.source, d.geometry " \
        "FROM (SELECT #{columns(collection)}, bbox AS box " \
        "FROM read_parquet([#{files.map { |f| quote(f) }.join(", ")}]) " \
        "WHERE #{box_filter("bbox", envelope)} AND (#{any}) AND #{filter(collection)}) d " \
        "JOIN boxes p ON p.pin_index IN (#{indexes.join(", ")}) AND d.box.xmin <= p.x1 AND d.box.xmax >= p.x0 " \
        "AND d.box.ymin <= p.y1 AND d.box.ymax >= p.y0"
    end

    def box_filter(column, box)
      x0, y0, x1, y1 = box
      "#{column}.xmin <= #{x1} AND #{column}.xmax >= #{x0} AND #{column}.ymin <= #{y1} AND #{column}.ymax >= #{y0}"
    end

    # Buildings Overture took from OSM are buildings; its other sources are
    # treated as ML footprints. Roads and rail map to the build's classes.
    def columns(collection)
      case collection
      when "building"
        "id, CASE WHEN sources[1].dataset = 'OpenStreetMap' THEN 'building' ELSE 'ml_building' END AS feature, " \
        "class AS highway, names.\"primary\" AS name, sources[1].dataset AS source, " \
        "ST_AsGeoJSON(geometry)::VARCHAR AS geometry"
      when "segment"
        rail = RAIL_CLASSES.map { |k, v| "WHEN #{quote(k)} THEN #{quote(v)}" }.join(" ")
        "id, CASE subtype WHEN 'road' THEN 'road' ELSE 'railway' END AS feature, " \
          "CASE WHEN subtype = 'rail' THEN (CASE class #{rail} END) WHEN subclass = 'link' THEN class || '_link' " \
          "ELSE class END AS highway, names.\"primary\" AS name, NULL AS source, " \
          "ST_AsGeoJSON(geometry)::VARCHAR AS geometry"
      else
        "id, 'parking' AS feature, NULL AS highway, names.\"primary\" AS name, NULL AS source, " \
        "ST_AsGeoJSON(geometry)::VARCHAR AS geometry"
      end
    end

    # Ground-level roads and rail; parking areas (not points); buildings
    # above ground.
    def filter(collection)
      case collection
      when "building" then "NOT coalesce(is_underground, false)"
      when "segment"
        "((subtype = 'road' AND class IN (#{ROAD_CLASSES.map { |c| quote(c) }.join(", ")})) " \
        "OR (subtype = 'rail' AND class IN (#{RAIL_CLASSES.keys.map { |c| quote(c) }.join(", ")}))) " \
        "AND NOT list_has_any(flatten(list_transform(coalesce(road_flags, []) || coalesce(rail_flags, []), " \
        "lambda f: f.\"values\")), ['is_tunnel', 'is_bridge'])"
      else
        "subtype = 'transit' AND class = 'parking' AND ST_GeometryType(geometry) IN ('POLYGON', 'MULTIPOLYGON')"
      end
    end

    def setup(options, remote:)
      ext = options[:extension_directory]
      [(DuckDB.extension_sql(ext, options.fetch(:duckdb, "duckdb")) if ext), "INSTALL spatial; LOAD spatial;",
       # Pins in the same files share one read of each file's metadata.
       (if remote
          # A region-only secret (no keys, so reads stay anonymous): DuckDB 2.0
          # deprecates SET s3_region and warns about it inside -json output.
          # CREATE SECRET prints a result row of its own, so it goes nowhere.
          "INSTALL httpfs; LOAD httpfs;\n.output #{File::NULL}\nCREATE TEMPORARY SECRET overture (TYPE s3, " \
            "REGION 'us-west-2', SCOPE 's3://overturemaps-us-west-2');\n.output\n" \
            "SET parquet_metadata_cache = true; SET enable_http_metadata_cache = true;"
        end)].compact.join("\n")
    end

    # Remote reads occasionally stall and DuckDB exits without a message;
    # one retry gets past that.
    def run(sql, options, attempts: 2)
      out, err, status = DuckDB.capture(options.fetch(:duckdb, "duckdb"), sql, "-json")
      unless status.success?
        return run(sql, options, attempts: attempts - 1) if err.strip.empty? && attempts > 1

        raise Error, "duckdb failed: #{err.strip.empty? ? "no message (network?)" : err.strip[0, 500]}"
      end
      raise Error, "duckdb output too large" if out.bytesize > MAX_OUTPUT_BYTES

      out.strip.empty? ? [] : JSON.parse(out)
    end

    # OSM and Overture, plus a line for each other source whose buildings
    # the result could use (buildings: :osm_filled or :ml). The source names
    # come from the data, so they're cleaned and capped like any map text.
    def attribution(features)
      used = features ? features.buildings.select { |b| b.kind == "ml_building" } : []
      sources = used.filter_map { |b| b.source.to_s.gsub(/[[:cntrl:]]/, "").strip[0, 80] }.reject(&:empty?)
      ATTRIBUTION + sources.uniq.sort.map { |s| "Building footprints: #{s} (via Overture Maps)" }
    end

    def quote(text) = DuckDB.quote(text)
  end
end
