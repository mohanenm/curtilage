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

  # The east region's outline is a triangle inside its bounding box: a pin in
  # the box but outside the outline isn't covered, and a pin whose search
  # box crosses the outline is only partly covered.
  def test_outlines_decide_coverage
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "east.json"),
                 JSON.generate(format: 1, region: "test/east", parquet: "east.parquet", bbox: [-85, 34, -80, 37],
                               outline: [[[-85, 34], [-80, 34], [-85, 37], [-85, 34]]]))
      cat = Curtilage::Catalogue.from_dir(dir)

      assert_equal :full, cat.coverage([-84.0, 34.5])
      assert_equal :none, cat.coverage([-80.5, 36.5])
      assert_empty cat.files_for([-80.5, 36.5])
      assert_equal :partial, cat.coverage([-82.5, 35.5], margin: 0.2)
      flagged = Curtilage.generate_one([-82.5, 35.5], [], ["east.parquet"], cat, {})

      assert_includes flagged.flags, :partial_data
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
