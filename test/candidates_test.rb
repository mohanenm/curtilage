# frozen_string_literal: true

require_relative "test_helper"
require "json"

class CandidatesTest < Minitest::Test
  include SyntheticScene

  # A second building 4 m east of the site's: the pin could mean either.
  def two_buildings = scene + [polygon("building", 6, 14, -6, 30, 6)]

  # The parking lot west of the building also touches three more buildings:
  # a shopping-centre lot.
  def shared_lot
    scene + [polygon("building", 21, -58, -20, -48, -12, type: "retail"),
             polygon("building", 22, -58, -8, -48, 0, type: "retail"),
             polygon("building", 23, -58, 4, -48, 12, type: "retail")]
  end

  def test_none_unless_asked
    assert_nil Curtilage.generate(PIN, two_buildings).candidates
  end

  def test_another_building_near_the_pin
    r = Curtilage.generate(PIN, two_buildings, candidates: 3)
    other = r.candidates.find { |c| c.building == 6 }

    assert_equal 1, r.building
    assert_includes other.flags, :pin_moved
    assert_equal "candidate", other.steps.first[:step]
    assert_equal PIN, other.pin_quality[:moved_from]
    assert_operator other.confidence, :<, r.confidence
  end

  def test_the_whole_centre_on_a_shared_lot
    r = Curtilage.generate(PIN, shared_lot, candidates: 3)
    centre = r.candidates.find { |c| c.steps.first[:rule] == "scope" }

    assert_includes centre.flags, :shopping_centre
    refute_equal r.ring, centre.ring
  end

  def test_the_building_rectangle_when_confidence_is_low
    r = Curtilage.generate(PIN, scene)
    r.flags.push(:fallback, :near_houses) # confidence 0.6

    list = Curtilage::Candidates.for(r, PIN, scene, {}, 3)

    assert_equal [:building], list.map(&:method_name)
    assert_empty Curtilage::Candidates.for(Curtilage.generate(PIN, scene), PIN, scene, {}, 3)
  end

  def test_most_confident_first_and_capped
    r = Curtilage.generate(PIN, shared_lot + [polygon("building", 6, 14, -6, 30, 6)], candidates: 1)

    assert_equal 1, r.candidates.size
    all = Curtilage.generate(PIN, shared_lot + [polygon("building", 6, 14, -6, 30, 6)], candidates: 5).candidates

    assert_equal all.map(&:confidence).sort.reverse, all.map(&:confidence)
    assert_equal all.first.ring, r.candidates.first.ring
  end

  def test_the_count_is_checked_before_any_work
    [0, 6, "2", 1.5].each do |bad|
      assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, candidates: bad) }
      assert_raises(ArgumentError) { Curtilage.generate_many([PIN], parquet: "missing.parquet", candidates: bad) }
    end
  end

  def test_candidates_in_every_output
    results = [Curtilage.generate(PIN, two_buildings, candidates: 2)]
    roles = JSON.parse(Curtilage::Formats.write(results, :geojson))["features"].map { |f| f["properties"]["role"] }
    line = JSON.parse(Curtilage::Formats.write(results, :ndjson))
    row = Curtilage::Formats.parse_csv(Curtilage::Formats.write(results, :csv))[1]

    assert_includes roles, "candidate"
    assert_equal 1, line["properties"]["candidates"][0]["rank"]
    assert_equal results[0].candidates.size.to_s, row[Curtilage::Formats::CSV_COLUMNS.index("candidates")]
    assert_includes Curtilage::Formats.write(results, :kml), "1 candidate 1"
    assert_includes Curtilage::Preview.html(results), "other candidate(s)"
  end
end
