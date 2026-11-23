# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "time"

module Curtilage
  # Builds a region's features Parquet from Geofabrik's free shapefiles:
  # find the newest dated extract, download only the layers used (range
  # requests, CRC-checked; the whole zip plus unzip only if the server can't
  # do ranges), and run sql/build_from_shapefiles.sql with the DuckDB CLI.
  # Optionally adds machine-learned building footprints (see Footprints).
  #
  # Network access is limited to Geofabrik (and the footprint host when asked
  # for). Memory is capped (400 MB and 1 thread by default) so a build fits a
  # 1 GB dyno; DuckDB spills to work_dir when a region is bigger than that.
  module Build
    class Error < Curtilage::Error; end

    HOST = "download.geofabrik.de"
    US = "north-america/us"
    # Regions Geofabrik only publishes as shapefiles in parts.
    PARTS = {
      "#{US}/california" => %W[#{US}/california/norcal #{US}/california/socal],
    }.freeze
    LAYERS = %w[buildings_a traffic_a roads railways].freeze
    LAYER_PATTERNS = LAYERS.map { |layer| "gis_osm_#{layer}_free_*" }.freeze
    REGION = %r{\A[a-z]+(-[a-z]+)*(/[a-z]+(-[a-z]+)*)*\z}
    MAX_DOWNLOAD_BYTES = 5_000_000_000
    LOOKBACK_DAYS = 8
    SQL_FILE = File.expand_path("../../sql/build_from_shapefiles.sql", __dir__)

    OPTIONS = {
      date: nil, memory_limit: "400MB", threads: 1, timeout: 3600,
      ml_footprints: nil, keep_downloads: false, name: nil, outline: nil, log: $stderr
    }.freeze

    module_function

    # region: a US state ("tennessee", "new-york") or any Geofabrik region
    # path ("europe/germany/bayern", "north-america/canada/ontario").
    # options: see OPTIONS; ml_footprints: "microsoft" adds ML footprints;
    # outline: the region's outline rings (default: from Geofabrik's index),
    # stored so a Catalogue knows exactly where the data stops;
    # duckdb: and extension_directory: default to Curtilage.config.
    # Returns the Parquet path, named after the region's last part unless
    # name: says otherwise.
    def run(region, out_dir:, work_dir:, **options)
      opts = OPTIONS.merge(Curtilage.duckdb_options(options))
      path = region_path(region)
      check_options(opts)
      FileUtils.mkdir_p([out_dir, work_dir])
      fetched = PARTS.fetch(path, [path]).map { |part| [part, *fetch(part, opts[:date], work_dir, opts[:log])] }
      dirs = fetched.map { |_, dir, _| dir }
      opts = opts.merge(temp_directory: File.join(work_dir, "duckdb_tmp"))
      ml, ml_bbox = ml_files(dirs, work_dir, opts)
      out = File.join(out_dir, "#{output_name(path, opts[:name])}.parquet")
      build_parquet(sql(dirs, "#{out}.tmp", opts, ml_files: ml, ml_bbox: ml_bbox), out, opts)
      write_metadata(out, path, fetched.map(&:last), opts.merge(provenance(fetched, ml)))
      out
    ensure
      cleanup(work_dir, dirs, opts[:keep_downloads]) if dirs
    end

    # What was downloaded, for the metadata: each part's layer files and
    # each footprint tile, with sizes and SHA256s.
    def provenance(fetched, ml_files)
      { sources: fetched.map { |part, dir, date| source_record(part, date, dir) },
        ml_sources: ml_files.map { |f| record(f) } }
    end

    def build_parquet(sql, out, opts)
      opts[:log].puts "building #{out}"
      run_duckdb(sql, opts[:duckdb], timeout: opts[:timeout])
      File.rename("#{out}.tmp", out)
    end

    def output_name(path, name)
      name ||= File.basename(path)
      raise ArgumentError, "bad output name #{name.inspect}" unless name.match?(/\A[a-z0-9-]+\z/)

      name
    end

    def region_path(region)
      region = region.to_s
      raise ArgumentError, "unknown region: #{region.inspect}" unless region.match?(REGION)

      region.include?("/") ? region : "#{US}/#{region}"
    end

    # date: goes into a file name and a URL, so only YYMMDD will do.
    def check_options(opts)
      date = opts[:date]
      raise ArgumentError, "date is YYMMDD: #{date.inspect}" unless date.nil? || date.to_s.match?(/\A\d{6}\z/)

      source = opts[:ml_footprints]
      return if source.nil? || Footprints::SOURCES.include?(source.to_s)

      raise ArgumentError, "unknown ml_footprints source #{source.inspect} (have: #{Footprints::SOURCES.join(", ")})"
    end

    # Fetches one Geofabrik extract's layers (see above); returns [folder
    # with its shapefiles, extract date].
    #
    # Unless the whole zip is already on disk, only the layers used are
    # downloaded, with range requests (ZipRange); a server or zip that can't
    # do that gets the whole file instead.
    def fetch(part, date, work_dir, log)
      date ||= latest_date(part)
      name = "#{part.tr("/", "-")}-#{date}-free.shp.zip"
      zip = File.join(work_dir, name)
      dir = File.join(work_dir, File.basename(name, ".shp.zip"))
      return [dir, date] if !File.file?(zip) && fetch_layers(part, date, dir, log)

      unless File.file?(zip)
        log.puts "downloading https://#{HOST}#{url_path(part, date)}"
        Download.fetch(HOST, url_path(part, date), zip, max_bytes: MAX_DOWNLOAD_BYTES)
      end
      check_zip(zip)
      ZipRange.check_local(zip, LAYER_PATTERNS, max_bytes: MAX_DOWNLOAD_BYTES)
      unzip_layers(zip, dir)
      [dir, date]
    end

    def fetch_layers(part, date, dir, log)
      log.puts "downloading the layers used from https://#{HOST}#{url_path(part, date)}"
      ZipRange.extract(HOST, url_path(part, date), LAYER_PATTERNS, dir, max_bytes: MAX_DOWNLOAD_BYTES)
      true
    rescue ZipRange::Unsupported => e
      log.puts "range download not possible (#{e.message}); downloading the whole file"
      FileUtils.rm_rf(dir)
      false
    end

    def url_path(part, date) = "/#{part}-#{date}-free.shp.zip"

    # Geofabrik publishes dated files daily; today's may not be up yet.
    def latest_date(part, today: Date.today)
      LOOKBACK_DAYS.times do |i|
        date = (today - i).strftime("%y%m%d")
        return date if Download.exists?(HOST, url_path(part, date))
      end
      raise Error, "Geofabrik has no dated shapefile for #{part} in the last #{LOOKBACK_DAYS} days " \
                   "(large regions are only offered as sub-regions)"
    end

    # Geofabrik publishes no checksum for shapefiles; the zip's CRCs catch a
    # truncated or corrupt download.
    def check_zip(zip)
      _, err, status = unzip("-tq", zip)
      return if status.success?

      File.delete(zip)
      raise Error, "corrupt download #{File.basename(zip)} (deleted): #{err.strip[0, 200]}"
    end

    def unzip(*)
      Open3.capture3("unzip", *)
    rescue Errno::ENOENT
      raise Error, "unzip not found: it's needed when a server can't serve byte ranges"
    end

    def unzip_layers(zip, dir)
      FileUtils.mkdir_p(dir)
      # -j: junk any folders in member names, so files land only in dir.
      _, err, status = unzip("-joq", zip, *LAYER_PATTERNS, "-d", dir)
      raise Error, "unzip failed: #{err.strip[0, 200]}" unless status.success?
    end

    # [footprint tiles covering the region's extent, that extent], or [[],
    # nil] when not asked for.
    def ml_files(dirs, work_dir, opts)
      return [[], nil] unless opts[:ml_footprints]

      bbox = extent(dirs, opts)
      files = Footprints.microsoft(bbox, File.join(work_dir, "ml_footprints"), log: opts[:log])
      raise Error, "no ML footprint tiles cover #{bbox.inspect}" if files.empty?

      [files, bbox]
    end

    # [min_lng, min_lat, max_lng, max_lat] of the region's roads.
    def extent(dirs, opts)
      query = "SELECT min(ST_XMin(geom)) a, min(ST_YMin(geom)) b, max(ST_XMax(geom)) c, max(ST_YMax(geom)) d " \
              "FROM roads_src;"
      out = run_duckdb([setup(opts), "INSTALL spatial; LOAD spatial;", layer_view("roads", dirs), query].join("\n"),
                       opts[:duckdb], "-json")
      row = JSON.parse(out).first
      %w[a b c d].map { |k| Float(row[k]) }
    end

    # The build query reads one view per layer; large layers come in parts
    # (_1, _2, ...) and multi-part regions in several folders.
    def sql(dirs, out, opts, ml_files: [], ml_bbox: nil)
      views = LAYERS.map { |layer| layer_view(layer, dirs) }
      [setup(opts), "INSTALL spatial; LOAD spatial;", *views, ml_view(ml_files, ml_bbox),
       "SET VARIABLE out_path = #{quote(out)};", File.read(SQL_FILE)].join("\n")
    end

    def layer_view(layer, dirs)
      files = dirs.flat_map { |d| Dir.glob(File.join(d, "gis_osm_#{layer}_free_*.shp")) }.sort
      raise Error, "no #{layer} shapefile in #{dirs.join(", ")}" if files.empty?

      reads = files.map { |f| "SELECT * FROM ST_Read(#{quote(f)})" }.join(" UNION ALL BY NAME ")
      "CREATE VIEW #{layer}_src AS #{reads};"
    end

    # ML footprints within the region's extent (tiles overhang it), or an
    # empty view.
    def ml_view(files, bbox)
      return "CREATE VIEW ml_buildings_src AS SELECT NULL::GEOMETRY AS geom WHERE false;" if files.empty?

      list = files.map { |f| quote(f) }.join(", ")
      min_lng, min_lat, max_lng, max_lat = bbox.map { |v| Float(v) }
      "CREATE VIEW ml_buildings_src AS SELECT geom FROM (SELECT ST_GeomFromGeoJSON(geometry) AS geom " \
        "FROM read_json([#{list}], format = 'newline_delimited', compression = 'gzip', " \
        "columns = {geometry: 'JSON'})) WHERE ST_Intersects(geom, ST_MakeEnvelope(" \
        "#{min_lng}, #{min_lat}, #{max_lng}, #{max_lat}));"
    end

    def setup(opts)
      ext = opts[:extension_directory]
      [(DuckDB.extension_sql(ext, opts[:duckdb]) if ext),
       DuckDB.memory_limit(opts[:memory_limit]),
       "SET threads = #{threads(opts[:threads])};",
       ("SET temp_directory = #{quote(opts[:temp_directory])};" if opts[:temp_directory])].compact.join("\n")
    end

    def threads(value)
      count = Integer(value, exception: false)
      raise ArgumentError, "threads must be a whole number from 1 to 64: #{value.inspect}" unless count&.between?(1, 64)

      count
    end

    def run_duckdb(sql, duckdb, *, timeout: OPTIONS[:timeout])
      out, err, status = DuckDB.capture(duckdb, sql, *, timeout: timeout)
      raise Error, "duckdb failed: #{err.strip[0, 500]}" unless status.success? && err.strip.empty?

      out
    end

    # The region's outline from Geofabrik's index (all parts for a
    # multi-part region), or nil if the index can't be read.
    def outline(path, log)
      parts = PARTS.fetch(path, [path])
      rings = Regions.download.regions.select { |r| parts.include?(r.path) }.flat_map(&:rings)
      rings.empty? ? nil : rings
    rescue Download::Error, JSON::ParserError => e
      log.puts "no outline for #{path} (#{e.message}); the catalogue will use its bounding box"
      nil
    end

    # Writes <region>.json next to the Parquet file: what it holds, where it
    # came from and how to attribute it. Catalogue reads these. The outline
    # comes from Geofabrik's index only when the caller didn't pass one
    # (AutoData does, so the index isn't downloaded twice).
    def write_metadata(parquet, path, dates, opts)
      stats = run_duckdb([setup(opts), "SELECT feature, count(*) AS n, min(min_lng) a, min(min_lat) b, " \
                                       "max(max_lng) c, max(max_lat) d FROM read_parquet(#{quote(parquet)}) " \
                                       "GROUP BY feature;"].join("\n"), opts[:duckdb], "-json")
      rows = JSON.parse(stats)
      opts = opts.merge(outline: opts[:outline] || outline(path, opts[:log]))
      file = parquet.sub(/\.parquet\z/, ".json")
      upstream_changes(previous_metadata(file), opts[:sources]).each do |name|
        opts[:log].puts "warning: #{name} differs from the copy the last build of this region used " \
                        "(republished upstream, or altered in transit): check before trusting either build"
      end
      AutoData.write_atomically(file, JSON.pretty_generate(metadata(parquet, path, dates, rows, opts)))
    end

    def metadata(parquet, path, dates, rows, opts)
      source_dates = dates.map { |d| Date.strptime(d, "%y%m%d").iso8601 }
      {
        region: path, parquet: File.basename(parquet), format: 1,
        source: "Geofabrik OpenStreetMap shapefiles", source_dates: source_dates,
        built_at: Time.now.utc.iso8601, ml_footprints: opts[:ml_footprints],
        bbox: bbox_of(rows),
        counts: rows.to_h { |r| [r["feature"], r["n"]] },
        licence: "ODbL-1.0", attribution: attribution(opts[:ml_footprints]),
        outline: rounded(opts[:outline]), sources: opts[:sources], ml_sources: opts[:ml_sources],
        parquet_bytes: File.size?(parquet), parquet_sha256: sha256(parquet), gem_version: VERSION
      }.compact
    end

    # What was downloaded for one part: its dated zip's name and each layer
    # file taken from it, with size and SHA256. Geofabrik publishes no
    # checksums, so this is what a later build compares against.
    def source_record(part, date, dir)
      files = LAYER_PATTERNS.flat_map { |pattern| Dir.glob(File.join(dir, pattern)) }.sort
      { "file" => File.basename(url_path(part, date)), "members" => files.to_h { |f| [File.basename(f), record(f)] } }
    end

    def record(file)
      { "file" => File.basename(file), "bytes" => File.size(file), "sha256" => Digest::SHA256.file(file).hexdigest }
    end

    # Dated files whose contents differ from what the previous build of
    # this region recorded under the same name: Geofabrik republished them,
    # or something altered them on the way. Either way, worth a look.
    def upstream_changes(previous, sources)
      before = Array(previous && previous["sources"]).to_h { |s| [s["file"], s["members"]] }
      Array(sources).filter_map { |s| s["file"] if before[s["file"]] && before[s["file"]] != s["members"] }
    end

    def previous_metadata(file)
      File.file?(file) ? JSON.parse(File.read(file, encoding: "utf-8")) : nil
    rescue JSON::ParserError
      nil
    end

    def sha256(file)
      File.file?(file) ? Digest::SHA256.file(file).hexdigest : nil
    end

    def bbox_of(rows)
      %w[a b].map { |k| rows.map { |r| r[k] }.min } + %w[c d].map { |k| rows.map { |r| r[k] }.max }
    end

    def rounded(rings)
      rings&.map { |ring| ring.map { |lng, lat| [lng.round(5), lat.round(5)] } }
    end

    def attribution(ml_footprints)
      ["© OpenStreetMap contributors",
       ("Microsoft Global ML Building Footprints (CDLA Permissive 2.0)" if ml_footprints)].compact
    end

    def cleanup(work_dir, dirs, keep_downloads)
      dirs.each { |d| FileUtils.rm_rf(d) }
      FileUtils.rm_rf(File.join(work_dir, "duckdb_tmp"))
      return if keep_downloads

      Dir.glob(File.join(work_dir, "*.shp.zip")).each { |z| File.delete(z) }
      FileUtils.rm_rf(File.join(work_dir, "ml_footprints"))
    end

    def quote(text) = DuckDB.quote(text)
  end
end
