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
      @temporary = @opts[:cache_dir].nil?
      @cache_dir = @opts[:cache_dir] || Dir.mktmpdir("curtilage")
      FileUtils.mkdir_p(@cache_dir)
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
      workers = Array.new(@opts[:parallel_builds].to_i.clamp(1, [needed.size, 1].max)) do
        Thread.new { ensure_built(queue.pop) until queue.empty? }
      end
      workers.each(&:join)
      Catalogue.from_dir(@cache_dir)
    end

    def cleanup
      FileUtils.rm_rf(@cache_dir) if @temporary
    end

    def regions
      @regions ||= @opts[:regions] || load_regions
    end

    def name(region) = region.path.tr("/", "-")

    private

    def ensure_built(region)
      with_lock(name(region)) do
        next if fresh?(File.join(@cache_dir, "#{name(region)}.json"))

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

    def fresh?(metadata_file)
      return false unless File.file?(metadata_file)

      built = Time.parse(JSON.parse(File.read(metadata_file))["built_at"].to_s)
      Time.now - built < @opts[:max_age_days] * 86_400
    rescue ArgumentError, JSON::ParserError
      false
    end

    # Two jobs sharing a cache build each region once.
    def with_lock(key, &)
      File.open(File.join(@cache_dir, ".#{key}.lock"), File::CREAT | File::RDWR) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def load_regions
      file = File.join(@cache_dir, INDEX_FILE)
      unless File.file?(file) && Time.now - File.mtime(file) < @opts[:max_age_days] * 86_400
        File.write(file, Download.read(Regions::HOST, Regions::INDEX, max_bytes: Regions::MAX_INDEX_BYTES))
      end
      Regions.parse(File.read(file))
    end
  end
end
