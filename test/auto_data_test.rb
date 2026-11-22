# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"
require "stringio"

class AutoDataTest < Minitest::Test
  def square(x0, y0, x1, y1)
    [[[[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]]]
  end

  def region(id, shp, coordinates)
    { properties: { id: id, urls: shp ? { shp: shp } : {} },
      geometry: { type: "MultiPolygon", coordinates: coordinates } }
  end

  def index
    base = "https://download.geofabrik.de/test"
    JSON.generate(features: [
                    region("big", "#{base}/big-latest-free.shp.zip", square(-90, 30, -70, 40)),
                    region("east", "#{base}/big/east/east-latest-free.shp.zip", square(-80, 30, -70, 40)),
                    region("noshp", nil, square(-180, -90, 180, 90)),
                    region("evil", "https://example.com/x-latest-free.shp.zip", square(-180, -90, 180, 90)),
                  ])
  end

  def test_regions_pick_the_smallest_with_shapefiles
    regions = Curtilage::Regions.parse(index)

    assert_equal %w[test/big test/big/east], regions.regions.map(&:path).sort
    assert_equal "test/big/east", regions.for([-75.0, 35.0]).path
    assert_equal "test/big", regions.for([-85.0, 35.0]).path
    assert_nil regions.for([0.0, 0.0])
    assert_equal 2, regions.around([-80.0, 35.0], 0.01).size
  end

  def test_builds_each_missing_region_once_then_reuses_it
    built = []
    builder = lambda do |region, dir, name|
      built << region.path
      File.write(File.join(dir, "#{name}.json"),
                 JSON.generate(format: 1, region: region.path, parquet: "#{name}.parquet", bbox: region.bbox,
                               built_at: Time.now.utc.iso8601))
    end
    Dir.mktmpdir do |dir|
      2.times do
        auto = Curtilage::AutoData.new(cache_dir: dir, regions: Curtilage::Regions.parse(index), builder: builder,
                                       log: StringIO.new)
        catalogue = auto.catalogue_for([[-75.0, 35.0], [-76.0, 36.0], [0.0, 0.0]])

        assert_equal [File.join(dir, "test-big-east.parquet")], catalogue.files_for([-75.0, 35.0])
      end

      assert_equal ["test/big/east"], built
    end
  end

  def test_parallel_builds_build_each_region_once
    built = Queue.new
    builder = lambda do |region, dir, name|
      sleep 0.05
      built << region.path
      File.write(File.join(dir, "#{name}.json"),
                 JSON.generate(format: 1, region: region.path, parquet: "#{name}.parquet", bbox: region.bbox,
                               built_at: Time.now.utc.iso8601))
    end
    Dir.mktmpdir do |dir|
      auto = Curtilage::AutoData.new(cache_dir: dir, regions: Curtilage::Regions.parse(index), builder: builder,
                                     log: StringIO.new, parallel_builds: 3)
      auto.catalogue_for([[-75.0, 35.0], [-85.0, 35.0]])

      assert_equal %w[test/big test/big/east], Array.new(built.size) { built.pop }.sort
    end
  end

  # :auto builds a region only when enough pins share it (or it's cached);
  # scattered pins, and pins outside every region, are read from Overture.
  def test_auto_plan_builds_dense_regions_and_reads_sparse_ones
    auto = Curtilage::AutoData.new(regions: Curtilage::Regions.parse(index), builder: ->(*) {}, log: StringIO.new)
    pins = [[-75.0, 35.0], [-75.1, 35.1], [-75.2, 35.2], [-85.0, 35.0], [10.0, 50.0]]
    built, read = Curtilage.auto_plan(pins, auto, 3)

    assert_equal [0, 1, 2], built
    assert_equal [3, 4], read
    assert_equal [[], [0, 1, 2, 3, 4]], Curtilage.auto_plan(pins, auto, 10)
  ensure
    auto&.cleanup
  end

  def test_temporary_cache_is_removed
    auto = Curtilage::AutoData.new(regions: Curtilage::Regions.parse(index), builder: ->(*) {}, log: StringIO.new)
    dir = auto.cache_dir

    assert Dir.exist?(dir)
    auto.cleanup

    refute Dir.exist?(dir)
  end
end
