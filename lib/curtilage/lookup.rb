# frozen_string_literal: true

require "json"

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
    class Error < Curtilage::Error; end

    # About 400 m north-south and 450 m east-west at US latitudes: room for
    # the lot and its bounding roads.
    DEFAULT_RADIUS_DEG = 0.004
    MAX_OUTPUT_BYTES = 200_000_000
    # A lookup only reads the row groups near its pins: this is headroom.
    DEFAULT_MEMORY = "1GB"
    # Each pin is one scan in a UNION ALL, and DuckDB refuses queries nested
    # more than 1,000 deep: larger batches take several calls.
    PINS_PER_CALL = 500
    REMOTE = %r{\A(s3|gs|gcs|https)://}

    module_function

    # Feature hashes for one pin. parquet: a path or URL, or a list of them.
    def features(parquet:, pin:, **)
      features_many(parquet: parquet, pins: [pin], **).first
    end

    # One DuckDB call for many pins; returns a list of feature lists in pin
    # order.
    #
    # options: duckdb (CLI path), extension_directory (both default to
    # Curtilage.config), radius_deg, setup_sql.
    def features_many(parquet:, pins:, **options)
      options = Curtilage.duckdb_options(options)
      files = Array(parquet)
      check_files(files)
      raise ArgumentError, "no pins given" if pins.empty?

      pins.each_slice(PINS_PER_CALL).flat_map { |batch| read_batch(files, batch, options) }
    end

    def read_batch(files, pins, options)
      sql = sql(files, pins, options[:extension_directory], options.fetch(:radius_deg, DEFAULT_RADIUS_DEG),
                options[:setup_sql], duckdb: options.fetch(:duckdb, "duckdb"),
                                     memory_limit: options.fetch(:memory_limit, DEFAULT_MEMORY))
      out, err, status = DuckDB.capture(options.fetch(:duckdb, "duckdb"), sql, "-json",
                                        timeout: options.fetch(:timeout, Curtilage.config.duckdb_timeout),
                                        max_output: MAX_OUTPUT_BYTES)
      raise Error, "duckdb failed: #{err.strip[0, 500]}" unless status.success?

      group(out, pins.size)
    end

    def check_files(files)
      raise ArgumentError, "no parquet file given" if files.empty?

      files.each do |f|
        Curtilage.online!("reading #{f}") if f.to_s.match?(REMOTE)
        next if f.to_s.match?(REMOTE)
        raise ArgumentError, "parquet file not found: #{f}" unless File.file?(f.to_s)
      end
    end

    def group(out, count)
      group_rows(out.strip.empty? ? [] : JSON.parse(out), count)
    end

    # Rows tagged with pin_index -> one feature list per pin. Overture uses
    # it too.
    def group_rows(rows, count)
      lists = Array.new(count) { [] }
      rows.each do |row|
        index = row.delete("pin_index")
        lists[index] << row.merge("geometry" => JSON.parse(row["geometry"])) if index.is_a?(Integer)
      end
      lists
    end

    def sql(files, pins, extension_directory, radius_deg, setup_sql = nil, duckdb: nil, memory_limit: DEFAULT_MEMORY)
      r = Float(radius_deg)
      raise ArgumentError, "radius out of range" unless r.positive? && r <= 0.05

      [setup(files, extension_directory, setup_sql, duckdb, memory_limit), query(files, pins, r)].join("\n")
    end

    def setup(files, extension_directory, setup_sql, duckdb, memory_limit)
      [(DuckDB.extension_sql(extension_directory, duckdb) if extension_directory),
       DuckDB.memory_limit(memory_limit),
       DuckDB.load_sql("spatial"),
       (DuckDB.load_sql("httpfs") if files.any? { |f| f.to_s.match?(REMOTE) }),
       setup_sql].compact.join("\n")
    end

    # wkb::GEOMETRY: DuckDB 1.4 reads the column as a geometry already, 2.0
    # as bytes, and only a cast suits both.
    COLUMNS = "id, feature, highway, name, ST_AsGeoJSON(wkb::GEOMETRY)::VARCHAR AS geometry"

    # Local files: one scan joined to a table of the pins' boxes, about ten
    # times faster than a scan per pin (reading a local file whole is cheap).
    # Remote files: one scan per pin with constant bounds, so DuckDB reads
    # only the row groups (and files) near each pin, not whole files.
    def query(files, pins, radius)
      list = files.map { |f| quote(f) }.join(", ")
      boxes = pins.map do |pin|
        lng, lat = checked(pin)
        [lng - radius, lat - radius, lng + radius, lat + radius]
      end
      files.any? { |f| f.to_s.match?(REMOTE) } ? scan_per_pin(list, boxes) : joined(list, boxes)
    end

    def joined(list, boxes)
      rows = boxes.each_with_index.map { |(x0, y0, x1, y1), i| "(#{i}, #{x0}, #{y0}, #{x1}, #{y1})" }
      "CREATE TEMP TABLE boxes (pin_index INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE); " \
        "INSERT INTO boxes VALUES #{rows.join(", ")};\n" \
        "SELECT b.pin_index, #{COLUMNS} FROM read_parquet([#{list}]) f JOIN boxes b " \
        "ON f.max_lng >= b.x0 AND f.min_lng <= b.x1 AND f.max_lat >= b.y0 AND f.min_lat <= b.y1;"
    end

    def scan_per_pin(list, boxes)
      scans = boxes.each_with_index.map do |(x0, y0, x1, y1), i|
        "SELECT #{i} AS pin_index, #{COLUMNS} FROM read_parquet([#{list}]) " \
          "WHERE max_lng >= #{x0} AND min_lng <= #{x1} AND max_lat >= #{y0} AND min_lat <= #{y1}"
      end
      "#{scans.join(" UNION ALL ")};"
    end

    def checked(pin) = Validation.pin(pin)

    def quote(text) = DuckDB.quote(text)
  end
end
