# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

class ProfilesTest < Minitest::Test
  include SyntheticScene

  P = Curtilage::Profiles
  YAML_TEXT = <<~YAML
    big_box:
      preset: whole_lot
      parking_max_extent_m: 150
      buildings: osm_filled
      validation: { max_area_error_m2: 300000 }
    snug:
      preset: tight
      building_margin_m: 4
  YAML

  def test_yaml_and_json_give_the_same_options
    from_yaml = P.parse(YAML_TEXT, :yaml)
    from_json = P.parse(JSON.generate(Psych.safe_load(YAML_TEXT)), :json)

    assert_equal from_yaml, from_json
    assert_equal({ preset: :whole_lot, parking_max_extent_m: 150, buildings: :osm_filled,
                   validation: { max_area_error_m2: 300_000 } }, from_yaml[:big_box])
  end

  def test_a_profile_is_options_for_generate
    snug = P.parse(YAML_TEXT, :yaml)[:snug]
    r = Curtilage.generate(PIN, scene, **snug)

    assert_equal :building, r.method_name
    assert_in_delta 28 * 23, r.validation.metrics[:area_m2], 5 # 20 x 15 m plus 4 m all round
  end

  def test_mistakes_fail_naming_the_profile
    { "a:\n  grow_mm: 3\n" => "profile a: unknown option", "a:\n  grow_m: -3\n" => "profile a: grow_m",
      "a:\n  preset: roomy\n" => "profile a: unknown preset", "- a\n- b\n" => "map of name",
      "a: 3\n" => "map of name", "a: &x {grow_m: 3}\nb: *x\n" => "unreadable" }.each do |text, message|
      error = assert_raises(ArgumentError) { P.parse(text, :yaml) }

      assert_includes error.message, message
    end
  end

  def test_files_are_capped_and_typed_by_extension
    Dir.mktmpdir do |dir|
      json = File.join(dir, "p.json")
      File.write(json, JSON.generate(snug: { preset: "tight" }))

      assert_equal({ snug: { preset: :tight } }, P.load(json))
      big = File.join(dir, "big.yml")
      File.write(big, "a: {}\n#{"#" * P::MAX_BYTES}")

      assert_raises(ArgumentError) { P.load(big) }
      assert_raises(ArgumentError) { P.load(File.join(dir, "missing.yml")) }
    end
  end

  def test_the_cli_takes_a_profile_as_a_preset
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      File.write(File.join(dir, "profiles.yml"), YAML_TEXT)
      run = lambda do |*extra|
        Open3.capture3("ruby", "-I", lib, exe, "generate", "--pin", "-80,35", "--parquet",
                       File.join(dir, "region.parquet"), "--duckdb", fake, "--format", "ndjson",
                       "--profiles", File.join(dir, "profiles.yml"), *extra)
      end
      out, = run.call("--preset", "big_box", "--buildings", "osm")
      options = JSON.parse(out.force_encoding(Encoding::UTF_8))["properties"]["provenance"]["options"]

      assert_equal [150, "osm"], options.values_at("parking_max_extent_m", "buildings") # flags win over the profile
      _, err, status = run.call("--preset", "nope")

      assert_equal 2, status.exitstatus
      assert_includes err, "unknown preset"
    end
  end
end
