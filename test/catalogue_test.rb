# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class CatalogueTest < Minitest::Test
  def with_catalogue(base_url: nil)
    Dir.mktmpdir do |dir|
      { "east" => [-85, 34, -80, 37], "west" => [-90.5, 34, -84.99, 37] }.each do |name, bbox|
        File.write(File.join(dir, "#{name}.json"),
                   JSON.generate(format: 1, region: "test/#{name}", parquet: "#{name}.parquet", bbox: bbox,
                                 attribution: ["© OpenStreetMap contributors"]))
      end
      File.write(File.join(dir, "junk.json"), JSON.generate(hello: 1))
      yield Curtilage::Catalogue.from_dir(dir, base_url: base_url), dir
    end
  end

  def test_picks_the_files_covering_a_pin
    with_catalogue do |cat, dir|
      assert_equal 2, cat.regions.size
      assert_equal [File.join(dir, "east.parquet")], cat.files_for([-82.0, 35.0])
      assert_equal 2, cat.files_for([-84.995, 35.0]).size
      assert_empty cat.files_for([-100.0, 35.0])
    end
  end

  def test_base_url_points_at_a_bucket
    with_catalogue(base_url: "s3://maps/features/") do |cat, _|
      assert_equal ["s3://maps/features/east.parquet"], cat.files_for([-82.0, 35.0])
      assert_equal ["© OpenStreetMap contributors"], cat.attribution(cat.files_for([-82.0, 35.0]))
    end
  end

  def test_generate_many_flags_pins_with_no_data
    with_catalogue do |cat, _|
      results = Curtilage.generate_many([[-100.0, 35.0]], catalogue: cat)

      refute_predicate results.first, :ok?
      assert_includes results.first.flags, :no_data
    end
  end
end
