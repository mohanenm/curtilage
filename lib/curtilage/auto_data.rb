# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "tmpdir"

module Curtilage
  # Data on demand, so nothing has to be hosted: finds the regions the pins
  # are in (Regions), builds any that are missing or stale into cache_dir
  # (Build), and returns a Catalogue over them.
  #
  # With no cache_dir, everything goes in a temporary folder that cleanup
  # deletes: each run downloads and builds afresh (1-5 minutes per US state).
  # Give a persistent cache_dir to reuse builds until max_age_days.
  class AutoData
    INDEX_FILE = "geofabrik-index.json"

    OPTIONS = {
      cache_dir: nil, max_age_days: 31, ml_footprints: nil, duckdb: nil, extension_directory: nil,
      parallel_builds: 1,
      log: $stderr, builder: nil, regions: nil
    }.freeze

    attr_reader :cache_dir

    def initialize(**options)
      @opts = OPTIONS.merge(options.compact)
      check_options
      @temporary = @opts[:cache_dir].nil?
      @cache_dir = @opts[:cache_dir] || Dir.mktmpdir("curtilage")
      FileUtils.mkdir_p(@cache_dir, mode: 0o700)
      problem = AutoData.cache_problem(File.stat(@cache_dir), @cache_dir)
      raise Error, problem if problem
    end

    # Each build peaks near 600 MB; more than 8 at once would swamp most
    # machines and Geofabrik.
    MAX_PARALLEL_BUILDS = 8

    def check_options
      builds = @opts[:parallel_builds]
      unless builds.is_a?(Integer) && builds.between?(1, MAX_PARALLEL_BUILDS)
        raise ArgumentError, "parallel_builds must be a whole number from 1 to #{MAX_PARALLEL_BUILDS}: " \
                             "#{builds.inspect}"
      end

      age = @opts[:max_age_days]
      raise ArgumentError, "max_age_days must be a number of days from 0 to 3650: #{age.inspect}" \
        unless age.is_a?(Numeric) && age.to_f.finite? && age.between?(0, 3650)
    end

    # DuckDB reads the cache's Parquet files and the gem trusts its
    # metadata, so a cache someone else can write to is refused.
    def self.cache_problem(stat, dir)
      if stat.uid != Process.uid
        "the cache folder #{dir} belongs to another user: use a folder you own"
      elsif stat.mode.anybits?(0o002)
        "the cache folder #{dir} is writable by every user: run `chmod 700 #{dir}` or use another folder"
      end
    end

    # A Catalogue covering the pins, building what's missing first. Pins in
    # no region (open sea, or no Geofabrik shapefile) are simply not covered.
    #
    # Regions are built parallel_builds at a time (default 1: each build
    # peaks near 600 MB, so 1 suits a 1 GB machine; 2-3 roughly halve the
    # time on a bigger one).
    def catalogue_for(pins, margin: Lookup::DEFAULT_RADIUS_DEG)
      needed = pins.flat_map { |pin| regions.around(pin, margin) }.uniq(&:path)
      queue = Queue.new
      needed.each { |region| queue << region }
      # Closed, so pop returns nil once it's empty instead of waiting.
      queue.close
      workers = Array.new(@opts[:parallel_builds].clamp(1, [needed.size, 1].max)) do
        Thread.new do
          Thread.current.report_on_exception = false
          while (region = queue.pop)
            ensure_built(region)
          end
        rescue StandardError
          queue.clear # the others finish their build but start no new one
          raise
        end
      end
      Curtilage.join_all(workers) # cleanup may delete the folder they build in
      Catalogue.from_dir(@cache_dir)
    end

    def cleanup
      FileUtils.rm_rf(@cache_dir) if @temporary
    end

    def regions
      @regions ||= @opts[:regions] || load_regions
    end

    def name(region) = region.path.tr("/", "-")

    # Whether the region (by its Geofabrik path) is already built and fresh.
    def fresh_region?(path)
      fresh?(File.join(@cache_dir, "#{path.tr("/", "-")}.json"))
    end

    private

    def ensure_built(region)
      with_lock(name(region)) do
        next if fresh_region?(region.path)

        @opts[:log].puts "building #{region.path} into #{@cache_dir}"
        build(region)
      end
    end

    def build(region)
      return @opts[:builder].call(region, @cache_dir, name(region)) if @opts[:builder]

      Build.run(region.path, out_dir: @cache_dir, work_dir: File.join(@cache_dir, "work", name(region)),
                             name: name(region), outline: region.rings,
                             **@opts.slice(:ml_footprints, :duckdb, :extension_directory, :log))
    end

    # Built recently enough, with its Parquet file present at the size the
    # metadata recorded: a missing, truncated or replaced file is rebuilt.
    # (doctor --verify checks the full SHA256.)
    def fresh?(metadata_file)
      return false unless File.file?(metadata_file)

      meta = JSON.parse(File.read(metadata_file, encoding: "utf-8"))
      parquet = File.join(@cache_dir, File.basename(meta["parquet"].to_s))
      built = Time.parse(meta["built_at"].to_s)
      Time.now - built < @opts[:max_age_days] * 86_400 && File.file?(parquet) &&
        File.size(parquet) == meta["parquet_bytes"]
    rescue ArgumentError, TypeError, JSON::ParserError
      false
    end

    # Two jobs sharing a cache build each region once.
    def with_lock(key, &)
      File.open(File.join(@cache_dir, ".#{key}.lock"), File::CREAT | File::RDWR) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # Geofabrik's index, cached for max_age_days. A cached copy that can't
    # be read (cut short, say) is fetched again rather than trusted.
    def load_regions
      file = File.join(@cache_dir, INDEX_FILE)
      cached = File.file?(file) && Time.now - File.mtime(file) < @opts[:max_age_days] * 86_400 && read_index(file)
      return cached if cached

      json = Download.read(Regions::HOST, Regions::INDEX, max_bytes: Regions::MAX_INDEX_BYTES)
      regions = Regions.parse(json)
      Curtilage.write_atomically(file, json)
      regions
    end

    def read_index(file)
      Regions.parse(File.read(file, encoding: "utf-8"))
    rescue Error
      nil
    end
  end
end
