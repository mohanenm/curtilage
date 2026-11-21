# frozen_string_literal: true

require "json"
require "open3"

module Curtilage
  # Reads the features around pins from features Parquet files (built by
  # Curtilage::Build) with the DuckDB CLI. Shelling out keeps the gem free of
  # native dependencies; only the row groups near each pin are read.
  #
  # Files can be local paths or s3://, gs:// or https:// URLs (read in place
  # with DuckDB's httpfs extension). For private buckets, pass setup_sql
  # (e.g. a CREATE SECRET statement): it goes to DuckDB on stdin, never on
  # the command line.
  module Lookup
    class Error < StandardError; end

    # About 400 m north-south and 450 m east-west at US latitudes: room for
    # the lot and its bounding roads.
    DEFAULT_RADIUS_DEG = 0.004
    MAX_OUTPUT_BYTES = 200_000_000
    MAX_PINS = 10_000
    REMOTE = %r{\A(s3|gs|gcs|https)://}

    module_function

    # Feature hashes for one pin. parquet: a path or URL, or a list of them.
    def features(parquet:, pin:, **)
      features_many(parquet: parquet, pins: [pin], **).first
    end

    # One DuckDB call for many pins; returns a list of feature lists in pin
    # order.
    #
    # options: duckdb (CLI path), extension_directory, radius_deg, setup_sql.
    def features_many(parquet:, pins:, **options)
      files = Array(parquet)
      check_files(files)
      raise ArgumentError, "between 1 and #{MAX_PINS} pins" unless pins.size.between?(1, MAX_PINS)

      sql = sql(files, pins, options[:extension_directory], options.fetch(:radius_deg, DEFAULT_RADIUS_DEG),
                options[:setup_sql])
      out, err, status = Open3.capture3(options.fetch(:duckdb, "duckdb"), "-json", stdin_data: sql)
      raise Error, "duckdb failed: #{err.strip[0, 500]}" unless status.success?
      raise Error, "duckdb output too large" if out.bytesize > MAX_OUTPUT_BYTES

      group(out, pins.size)
    end

    def check_files(files)
      raise ArgumentError, "no parquet file given" if files.empty?

      files.each do |f|
        next if f.to_s.match?(REMOTE)
        raise ArgumentError, "parquet file not found: #{f}" unless File.file?(f.to_s)
      end
    end

    def group(out, count)
      lists = Array.new(count) { [] }
      rows = out.strip.empty? ? [] : JSON.parse(out)
      rows.each do |row|
        index = row.delete("pin_index")
        lists[index] << row.merge("geometry" => JSON.parse(row["geometry"])) if index.is_a?(Integer)
      end
      lists
    end

    def sql(files, pins, extension_directory, radius_deg, setup_sql = nil)
      r = Float(radius_deg)
      raise ArgumentError, "radius out of range" unless r.positive? && r <= 0.05

      [setup(files, extension_directory, setup_sql), query(files, pins, r)].join("\n")
    end

    def setup(files, extension_directory, setup_sql)
      [("SET extension_directory = #{quote(File.expand_path(extension_directory))};" if extension_directory),
       "LOAD spatial;",
       ("LOAD httpfs;" if files.any? { |f| f.to_s.match?(REMOTE) }),
       setup_sql].compact.join("\n")
    end

    # One scan per pin with constant bounds, so DuckDB can skip every row
    # group (and file) away from that pin; a join on a pins table can't.
    def query(files, pins, radius)
      list = files.map { |f| quote(f) }.join(", ")
      scans = pins.each_with_index.map do |pin, i|
        lng, lat = checked(pin)
        "SELECT #{i} AS pin_index, id, feature, highway, name, ST_AsGeoJSON(wkb)::VARCHAR AS geometry " \
          "FROM read_parquet([#{list}]) WHERE max_lng >= #{lng - radius} AND min_lng <= #{lng + radius} " \
          "AND max_lat >= #{lat - radius} AND min_lat <= #{lat + radius}"
      end
      "#{scans.join(" UNION ALL ")};"
    end

    def checked(pin)
      lng = Float(pin[0])
      lat = Float(pin[1])
      raise ArgumentError, "pin out of range: #{pin.inspect}" unless lng.abs <= 180 && lat.abs <= 90

      [lng, lat]
    end

    def quote(text)
      "'#{text.to_s.gsub("'", "''")}'"
    end
  end
end
