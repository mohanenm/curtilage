# frozen_string_literal: true

require_relative "test_helper"

# missing-buildings: sites with no OSM building, as tasks for mappers.
class MissingBuildingsTest < Minitest::Test
  include SyntheticScene

  M = Curtilage::MissingBuildings

  def empty_lot = [road(4, "secondary", [[-200, -40], [200, -40]])]

  def test_only_sites_without_a_building_become_tasks
    results = [Curtilage.generate(PIN, scene), Curtilage.generate(PIN, empty_lot)]
    tasks = M.features(results, %w[shop-1 shop-2])

    assert_equal 1, tasks.size
    assert_equal PIN, tasks[0][:geometry][:coordinates]
    refute tasks[0][:properties].key?(:id), "ids only when asked"
    refute tasks[0][:properties][:footprint_nearby]
    assert_equal "shop-2", M.features(results, %w[shop-1 shop-2], with_ids: true)[0][:properties][:id]
  end

  def test_a_footprint_nearby_is_a_hint
    with_ml = empty_lot + [polygon("ml_building", -1, -10, -7.5, 10, 7.5)]
    result = Curtilage.generate(PIN, with_ml, buildings: :osm)

    assert M.features([result], ["a"])[0][:properties][:footprint_nearby]
  end

  def test_maproulette_lines
    tasks = M.features([Curtilage.generate(PIN, empty_lot)] * 2, %w[a b])
    lines = M.write(tasks, maproulette: true).lines

    assert_equal 2, lines.size
    assert(lines.all? { |l| l.start_with?("\u001e") })
    assert_equal "FeatureCollection", JSON.parse(lines[0].delete("\u001e"))["type"]
    assert_equal 2, JSON.parse(M.write(tasks))["features"].size
  end
end
