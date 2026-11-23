# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  def with_driveway
    scene + [road(9, "service", [[-30, -15], [-30, -40]])]
  end

  def test_entrances_name_the_street_they_open_onto
    r = Curtilage.generate(PIN, with_driveway)
    entrance = r.entrances.first

    assert_equal [entrance[:point]], r.details[:access_points]
    assert_equal({ street: nil, street_class: "secondary", street_id: 4, driveway: 9 }, entrance.except(:point))
    assert_includes Curtilage::Formats.write([r], :kml), "1 entrance from secondary"
    assert_includes Curtilage::Preview.html([r]), "driveway entrance from secondary"
    assert_empty Curtilage.generate([-80.01, 35.01], scene).entrances
  end

  def test_details_describe_the_building_parking_frontage_and_driveway
    d = Curtilage.generate(PIN, with_driveway).details

    assert_equal 1, d[:building][:id]
    assert_equal 300, d[:building][:area_m2]
    assert_equal d[:building][:footprint].first, d[:building][:footprint].last
    # The whole 34 x 40 m lot is inside the premises.
    assert_in_delta 1360, d[:parking_area_m2], 5
    assert_equal 54, d[:parking_spaces_estimate]
    # Only the south edge runs along the road.
    assert_operator d[:frontage_m], :>, 30
    assert_operator d[:frontage_m], :<, 120
    access = G.project(d[:access_points], PIN)

    assert_equal 1, access.size
    assert_in_delta(-30, access[0][0], 0.5)
    assert_in_delta(-40, access[0][1], 0.5)
  end

  def test_no_driveway_no_access_points
    assert_empty Curtilage.generate(PIN, scene).details[:access_points]
  end

  def test_no_building_no_details
    result = Curtilage.generate(PIN, [road(4, "secondary", [[-200, -40], [200, -40]])])

    assert_nil result.details
    assert_equal "no premises: no building within 30 m of the pin " \
                 "(it may be missing from OpenStreetMap: try buildings: :osm_filled)", result.problem
    assert_nil Curtilage.generate(PIN, scene).problem
  end

  def test_old_constant_still_works
    assert_same Curtilage::Result, Curtilage::Generator::Result
  end

  def test_wkt
    result = Curtilage.generate(PIN, scene)

    assert_match(/\APOLYGON \(\(-80\.\d+ 34\.\d+, /, result.to_wkt)
    assert_equal result.ring.size, result.to_wkt.count(",") + 1
    assert result.store_wkt.start_with?("POLYGON ((")
    assert_nil Curtilage::Result.wkt(nil)
  end

  def test_geojson_carries_details_and_extra_properties
    json = Curtilage.generate(PIN, scene).to_geojson(include_store: true, properties: { id: "a1" })

    assert_equal(%w[premises store], json[:features].map { |f| f[:properties][:role] })
    assert(json[:features].all? { |f| f[:properties][:id] == "a1" })
    assert_equal 1, json[:features][0][:properties][:details][:building][:id]
  end

  def test_buffered_grows_with_round_corners_and_shrinks
    result = Curtilage.generate(PIN, scene)
    area = G.area(xy(result))
    grown = G.open_ring(G.project(result.buffered(10), PIN))
    shrunk = G.open_ring(G.project(result.buffered(-2), PIN))

    assert_operator G.area(grown), :>, area
    assert(xy(result).all? { |p| G.contains?(grown, p) })
    assert(xy(result).all? { |p| G.distance_to_edges(grown, p) >= 9.99 })
    assert_operator G.area(shrunk), :<, area
    assert(shrunk.all? { |p| G.contains?(xy(result), p) && G.distance_to_edges(xy(result), p) >= 1.99 })
    assert_nil result.buffered(-500)
    assert_equal result.buffered(10).first, result.buffered(10).last
  end

  def test_building_at_uses_the_premises_details
    fake = Curtilage.generate(PIN, scene)
    with_stub(Curtilage, :generate_many, ->(_pins, **) { [fake] }) do
      assert_equal 1, Curtilage.building_at(PIN)[:id]
    end
  end
end
