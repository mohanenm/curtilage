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

  def test_temporary_cache_is_removed
    auto = Curtilage::AutoData.new(regions: Curtilage::Regions.parse(index), builder: ->(*) {}, log: StringIO.new)
    dir = auto.cache_dir

    assert Dir.exist?(dir)
    auto.cleanup

    refute Dir.exist?(dir)
  end
end
