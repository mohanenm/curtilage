# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

class CorrectionsTest < Minitest::Test
  include SyntheticScene

  def square(x0, y0, x1, y1) = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]].map { |x, y| lnglat(x, y) }

  def premises = square(-40, -35, 40, 30)

  def test_a_correction_is_used_instead_of_generating
    fetched = []
    features = scene
    with_stub(Curtilage, :fetch_and_generate, lambda { |pins, **|
      fetched.concat(pins)
      pins.map { |p| Curtilage.generate(p, features) }
    }) do
      results = Curtilage.generate_many([PIN, lnglat(1, 1)], corrections: { 1 => premises })
      manual = results[1]

      assert_equal [PIN], fetched, "corrected pins fetch no data"
      assert_equal :manual, manual.method_name
      assert_predicate manual, :ok?
      assert_equal premises, manual.ring
      assert_equal({ source: "manual" }, manual.provenance[:data])
      assert_in_delta 1.0, manual.confidence
      assert_equal "manual", manual.steps.first[:step]
    end
  end

  def test_a_bad_correction_is_kept_but_not_ok
    unclosed = Curtilage::Corrections.result(PIN, premises[0..-2])

    refute_predicate unclosed, :ok?
    assert_includes unclosed.problem, "unclosed"
    assert_in_delta 0.0, unclosed.confidence
  end

  def test_a_store_zone_must_sit_inside
    inside = Curtilage::Corrections.result(PIN, premises, store_ring: square(-10, -7, 10, 7))
    outside = Curtilage::Corrections.result(PIN, premises, store_ring: square(30, -7, 50, 7))

    assert_equal square(-10, -7, 10, 7), inside.store_ring
    assert_nil outside.store_ring
    assert_includes outside.explanation.last, "dropped the corrected store zone"
  end

  def test_corrections_are_checked
    [[], { "1" => premises }, { 5 => premises }, { 0 => "ring" }].each do |bad|
      assert_raises(ArgumentError) { Curtilage.generate_many([PIN], corrections: bad) }
    end
  end

  def test_our_own_output_reads_back_as_corrections
    result = Curtilage.generate(PIN, scene)
    %i[geojson ndjson].each do |format|
      Dir.mktmpdir do |dir|
        file = File.join(dir, "out.#{format}")
        File.write(file, Curtilage::Formats.write([result], format, ids: ["shop-1"]))
        read = Curtilage::Formats.read_results(file)

        assert_equal [result.ring, result.store_ring], read["shop-1"].values_at(:ring, :store_ring)
        assert read["shop-1"][:properties]["ok"]
      end
    end
  end

  def test_result_files_are_checked
    point = { type: "Feature", id: "a", geometry: { type: "Point", coordinates: [1, 2] }, properties: {} }
    { '{"type":"Feature","geometry":null,"properties":{}}' => "has no id", JSON.generate(point) => "isn't a Polygon",
      "[1]" => "isn't a Feature" }.each do |text, message|
      error = assert_raises(ArgumentError) { Curtilage::Formats.parse_results(text, :geojson) }

      assert_includes error.message, message
    end
    huge = { type: "Feature", id: "a", properties: {}, geometry: { type: "Polygon", coordinates: [[[0, 0]] * 1_001] } }

    assert_raises(ArgumentError) { Curtilage::Formats.parse_results(JSON.generate(huge), :geojson) }
  end

  def test_the_cli_matches_corrections_by_id
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      fixes = { type: "FeatureCollection", features: [
        { type: "Feature", properties: { id: "2" }, geometry: { type: "Polygon", coordinates: [premises] } },
        { type: "Feature", properties: { id: "elsewhere" }, geometry: { type: "Polygon", coordinates: [premises] } },
      ] }
      File.write(File.join(dir, "fixes.geojson"), JSON.generate(fixes))
      out, err, = Open3.capture3("ruby", "-I", lib, exe, "generate", "--pin", "-80.01,35.01", "--pin", "-80,35",
                                 "--parquet", File.join(dir, "region.parquet"), "--duckdb", fake, "--format", "ndjson",
                                 "--corrections", File.join(dir, "fixes.geojson"))
      methods = out.force_encoding(Encoding::UTF_8).lines.map { |l| JSON.parse(l)["properties"]["method"] }

      assert_equal "manual", methods[1]
      refute_equal "manual", methods[0]
      assert_includes err, "1 correction(s) match no site id, e.g. elsewhere"
    end
  end
end
