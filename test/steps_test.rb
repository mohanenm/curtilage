# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class StepsTest < Minitest::Test
  include SyntheticScene

  def test_one_step_per_line_of_the_explanation
    r = Curtilage.generate(PIN, scene)

    assert_equal(r.explanation, r.steps.map { |s| s[:text] })
    assert_equal(%w[find_building grow trim_road claim_lot add_lot], r.steps.map { |s| s[:step] })
  end

  def test_steps_name_the_rule_features_distance_and_areas
    steps = Curtilage.generate(PIN, scene).steps.to_h { |s| [s[:step], s] }

    assert_equal [1], steps["find_building"][:features]
    assert_equal({ rule: "grow_m", features: [1], distance_m: 30 }, steps["grow"].slice(:rule, :features, :distance_m))
    trim = steps["trim_road"]

    assert_equal ["road_class_half_width", [4], 8.0], trim.values_at(:rule, :features, :distance_m)
    assert_equal steps["grow"][:area_after_m2], trim[:area_before_m2]
    assert_operator trim[:area_after_m2], :<, trim[:area_before_m2]
    assert_equal steps["add_lot"][:area_before_m2], trim[:area_after_m2]
    fixed = Curtilage.generate(PIN, scene, road_offset_m: 5).steps.find { |s| s[:step] == "trim_road" }

    assert_equal "road_offset_m", fixed[:rule]
  end

  def test_flags_and_neighbour_cuts_are_steps
    houses = scene + [polygon("building", 5, 25, -6, 35, 6, type: "house")]
    split = Curtilage.generate(PIN, houses).steps.find { |s| s[:step] == "split_neighbour" }

    assert_equal [5], split[:features]
    assert_equal :near_houses, split[:flag]
    assert_operator split[:area_after_m2], :<, split[:area_before_m2]
  end

  def test_fallback_data_and_error_steps_come_first
    no_building = Curtilage::Generator.propose(PIN, [road(4, "secondary", [[-200, -40], [200, -40]])])

    assert_equal(%w[fallback fallback], no_building.steps.first(2).map { |s| s[:step] })
    assert_equal(%w[grow_trim building], no_building.steps.first(2).map { |s| s[:rule] })
    assert_equal(no_building.explanation, no_building.steps.map { |s| s[:text] })
    error = Curtilage.send(:generate_safely, PIN, :not_features, { grow_m: -1 })

    assert_equal [{ step: "error", text: error.explanation.first, flag: :error }], error.steps
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "far.json"),
                 JSON.generate(format: 1, region: "test/far", parquet: "far.parquet", bbox: [10, 10, 11, 11]))
      cat = Curtilage::Catalogue.from_dir(dir)
      none = Curtilage.send(:generate_one, PIN, [], [], cat, {})

      assert_equal({ step: "data", text: "no map data covers this pin", flag: :no_data }, none.steps.first)
    end
  end

  def test_steps_are_in_the_geojson
    props = Curtilage.generate(PIN, scene).to_geojson[:properties]

    assert_equal "find_building", props[:steps].first[:step]
    assert_equal "grow", JSON.parse(JSON.generate(props))["steps"][1]["step"]
  end
end
