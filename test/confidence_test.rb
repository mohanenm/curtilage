# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

class ConfidenceTest < Minitest::Test
  include SyntheticScene

  C = Curtilage::Confidence

  def test_a_clean_site_scores_one_with_every_factor_listed
    r = Curtilage.generate(PIN, scene)

    assert_in_delta 1.0, r.confidence
    assert_equal(C::FACTORS.keys, r.confidence_factors.map { |f| f[:name] })
    assert(r.confidence_factors.all? { |f| f[:met] })
  end

  def test_each_unmet_factor_takes_its_weight_off
    # The tight preset stops 8 m round the building, short of the road.
    r = Curtilage.generate(PIN, scene, preset: :tight)

    assert_in_delta 1 - C::FACTORS[:road_frontage][0], r.confidence
    r.flags.push(:fallback, :near_houses)

    assert_in_delta 1 - 0.15 - 0.30 - 0.10, r.confidence
    assert_equal(%i[main_method road_frontage no_homes_next_door],
                 r.confidence_factors.reject { |f| f[:met] }.map { |f| f[:name] })
  end

  def test_unusable_results_score_zero
    none = Curtilage.generate([-80.01, 35.01], scene)
    error = Curtilage.send(:generate_safely, PIN, :not_features, { grow_m: -1 })

    assert_equal [0, 0], [none.confidence, error.confidence]
  end

  def test_confidence_is_in_every_output
    r = [Curtilage.generate(PIN, scene, preset: :tight)]
    props = JSON.parse(Curtilage::Formats.write(r, :geojson))["features"][0]["properties"]
    row = Curtilage::Formats.parse_csv(Curtilage::Formats.write(r, :csv))[1]

    assert_in_delta 0.85, props["confidence"]
    assert_equal "road_frontage", props["confidence_factors"].find { |f| !f["met"] }["name"]
    assert_equal "0.85", row[Curtilage::Formats::CSV_COLUMNS.index("confidence")]
    assert_includes Curtilage::Formats.write(r, :kml), "confidence 0.85"
  end

  def test_the_preview_sorts_by_confidence
    page = Curtilage::Preview.html([Curtilage.generate(PIN, scene)])

    assert_includes page, 'data-confidence="1.0"'
    assert_includes page, '<option value="confidence">Lowest confidence first</option>'
  end

  def test_min_confidence_leaves_out_low_results
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      args = ["--pin", "-80,35", "--parquet", File.join(dir, "region.parquet"), "--duckdb", fake, "--format", "ndjson"]

      out, err, status = Open3.capture3("ruby", "-I", lib, exe, "generate", *args, "--min-confidence", "0.5")

      assert_equal ["", 1], [out, status.exitstatus] # no map data: confidence 0, left out
      assert_includes err, "1 result(s) below --min-confidence 0.5 left out"
      out, = Open3.capture3("ruby", "-I", lib, exe, "generate", *args, "--min-confidence", "0")

      assert_equal 1, out.lines.size
      _, _, status = Open3.capture3("ruby", "-I", lib, exe, "generate", *args, "--min-confidence", "1.5")

      assert_equal 2, status.exitstatus
    end
  end
end
