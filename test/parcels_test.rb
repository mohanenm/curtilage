# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Property lines the caller supplies (made-up parcels).
class ParcelsTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  def parcel(id, x0, y0, x1, y1) = polygon("parcel", id, x0, y0, x1, y1).merge("feature" => "parcel")

  def test_premises_stay_in_the_buildings_parcel
    plain = Curtilage.generate(PIN, scene)
    clipped = Curtilage.generate(PIN, scene + [parcel(9, -50, -35, 20, 30)]) # holds the parking, not the east side
    ring = xy(clipped)

    assert clipped.ok?, clipped.validation.errors.inspect
    assert_operator G.area(ring), :<, G.area(xy(plain))
    assert_in_delta 20, G.bounds(ring)[2], 1.0 # to within a cell and the straightening
    assert_in_delta 30, G.bounds(ring)[3], 1.0
    assert(clipped.steps.any? { |s| s[:step] == "clip_parcel" })
    refute_includes clipped.flags, :beyond_parcel
    assert G.ring_inside?(G.open_ring(G.project(clipped.store_ring, PIN)), ring, 0.01)
  end

  # The scene's parking (west, x -45..-11) runs past a tight parcel: it
  # stays, flagged.
  def test_parking_past_the_parcel_stays_flagged
    result = Curtilage.generate(PIN, scene + [parcel(9, -15, -12, 15, 12)])

    assert result.ok?
    assert_includes result.flags, :beyond_parcel
    assert G.contains?(xy(result), [-30, 0])
  end

  def test_parcels_that_dont_hold_the_building_change_nothing
    elsewhere = [parcel(9, 100, 100, 150, 150)]

    assert_equal Curtilage.generate(PIN, scene).ring, Curtilage.generate(PIN, scene + elsewhere).ring
  end

  # A tract kilometres across is cut to a window round the pin.
  def test_huge_parcels_are_cut_to_a_window
    features = Curtilage::Features.new(PIN, [parcel(9, -5000, -5000, 5000, 5000)])

    assert_equal [-500, -500, 500, 500], G.bounds(features.parcels.first.xy).map(&:round)
  end

  def test_parcel_mode_clip_is_the_default
    with = scene + [parcel(9, -50, -35, 20, 30)]

    assert_equal Curtilage.generate(PIN, with).ring, Curtilage.generate(PIN, with, parcel_mode: :clip).ring
  end

  # Parking 40-85 m west of the building, past the rules' reach, inside the
  # building's parcel: :grow takes it in, :clip doesn't.
  def test_parcel_mode_grow_takes_in_paving_inside_the_parcel
    far = scene + [polygon("parking", 5, -95, -20, -50, 20), parcel(9, -100, -35, 40, 30)]
    clip = Curtilage.generate(PIN, far)
    grow = Curtilage.generate(PIN, far, parcel_mode: :grow)

    assert grow.ok?, grow.validation.errors.inspect
    refute G.contains?(xy(clip), [-80, 0])
    assert G.contains?(xy(grow), [-80, 0])
    plain = xy(Curtilage.generate(PIN, scene))
    assert(plain.all? { |p| G.contains?(xy(grow), p) || G.distance_to_edges(xy(grow), p) < 1.5 }) # only adds
  end

  # A parcel also holding two other businesses' buildings is a centre: only
  # a limit, as :clip.
  def test_shared_parcels_are_only_a_limit
    centre = scene + [polygon("building", 6, -10, 40, 10, 55), polygon("building", 7, 20, 40, 40, 55),
                      parcel(9, -100, -35, 45, 60)]
    grow = Curtilage.generate(PIN, centre, parcel_mode: :grow)

    assert_includes grow.flags, :shared_parcel
    assert_equal Curtilage.generate(PIN, centre).ring, grow.ring
  end

  # A building on two parcels uses both; a parcel mostly covered by the
  # site's own parking joins them (a lot split over parcels).
  def test_buildings_on_several_parcels_and_split_lots
    parcels = [parcel(8, -20, -35, 0, 30), parcel(9, 0, -35, 40, 30), parcel(10, -60, -35, -20, 30)]
    grow = Curtilage.generate(PIN, scene + parcels, parcel_mode: :grow)

    assert grow.ok?, grow.validation.errors.inspect
    assert G.contains?(xy(grow), [30, 20])
    assert G.contains?(xy(grow), [-40, 0])
  end

  # generate_many reads the parcels file and hands each pin its parcels.
  def test_generate_many_takes_a_parcels_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "parcels.geojson")
      File.write(path, JSON.generate("type" => "FeatureCollection", "features" => [parcel(9, -50, -35, 20, 30)]))
      raw = scene
      with_stub(Curtilage::Lookup, :features_many, ->(**) { [raw] }) do
        result = Curtilage.generate_many([PIN], parquet: path, parcels: path).first

        assert(result.steps.any? { |s| s[:step] == "clip_parcel" })
      end
    end
  end

  def test_geojson_parcels_are_read_near_the_pins_only
    Dir.mktmpdir do |dir|
      path = File.join(dir, "parcels.geojson")
      far = polygon("x", 2, 5_000, 5_000, 5_050, 5_050)
      File.write(path, JSON.generate("type" => "FeatureCollection",
                                     "features" => [parcel(1, -25, -30, 25, 25), far, { "geometry" => nil }]))
      found = Curtilage::Parcels.near(path, [PIN])

      assert_equal([1], found[PIN].map { |f| f["id"] })
      File.write(path, "{")
      assert_raises(ArgumentError) { Curtilage::Parcels.near(path, [PIN]) }
      assert_raises(ArgumentError) { Curtilage::Parcels.near(File.join(dir, "none.geojson"), [PIN]) }
    end
  end
end
