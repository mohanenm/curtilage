# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"
require "stringio"
require "tmpdir"

# Offline: the regional check's class mapping and paging, on made-up pages.
class BenchmarkRegionalTest < Minitest::Test
  B = CurtilageBenchmark
  ROADS = B::REGIONAL_LAYERS.fetch("dc").first
  SQUARE = { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 0]]] }.freeze

  def feature(code, geometry = SQUARE, owner: nil, id: 1)
    { "geometry" => geometry, "properties" => { "OBJECTID" => id, "FEATURECODE" => code, "ASRNAME" => owner }.compact }
  end

  def test_rows_keep_only_the_class_and_geometry
    assert_equal({ "class" => "parking", "geometry" => SQUARE }, B.regional_row(ROADS, feature(1070)))
    assert_equal "alley", B.regional_row(ROADS, feature(1060))["class"]
    parcels = B::REGIONAL_LAYERS.fetch("dc").last

    row = B.regional_row(parcels, feature(nil, owner: "A Person"))

    assert_equal({ "class" => "parcel", "geometry" => SQUARE }, row)
  end

  def test_rows_drop_unknown_classes_points_and_huge_outlines
    huge = { "type" => "Polygon", "coordinates" => [Array.new(B::REGIONAL_MAX_VERTICES + 1) { [0, 0] }] }

    assert_nil B.regional_row(ROADS, feature(9999))
    assert_nil B.regional_row(ROADS, feature(1050, { "type" => "Point", "coordinates" => [0, 0] }))
    assert_nil B.regional_row(ROADS, feature(1050, huge))
    assert_nil B.regional_row(ROADS, feature(1050, { "type" => "Polygon", "coordinates" => "bad" }))
  end

  # A made-up region round [-80, 35]: A is clear; B shares its parcel with
  # another business; C is 100 m from a held-out site; D is on a parcel but
  # no building; F is far from any parcel (outside the data).
  def test_selection_sorts_clear_and_unclear_sites
    skip "no DuckDB CLI" unless Curtilage::DuckDB.version(Curtilage.config.duckdb)

    Dir.mktmpdir do |dir|
      write_region(dir)
      sql = B.regional_select_sql("dc", dir, [lnglat(0, 2100)])
      _, err, status = Curtilage::DuckDB.capture(Curtilage.config.duckdb, sql)

      assert status.success?, err
      rows = JSON.parse(File.read(File.join(dir, "selection.json"))).to_h { |r| [r["id"], r] }

      assert_equal %w[A B D], rows.keys.sort
      assert_equal ["clear", []], rows["A"].values_at("group", "reasons")
      assert_equal ["other businesses on the parcel"], rows["B"]["reasons"]
      assert_equal ["no single building at the pin"], rows["D"]["reasons"]
    end
  end

  def lnglat(x, y) = [-80.0 + (x / 91_290.0), 35.0 + (y / 110_950.0)]

  def square(x, y, half)
    ring = [[-1, -1], [1, -1], [1, 1], [-1, 1], [-1, -1]].map { |a, b| lnglat(x + (a * half), y + (b * half)) }
    { "type" => "Polygon", "coordinates" => [ring] }
  end

  def rectangle(x0, y0, x1, y1)
    ring = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]].map { |x, y| lnglat(x, y) }
    { "type" => "Polygon", "coordinates" => [ring] }
  end

  # Site A's premises: one taking in its building, its parking and a 10 m
  # strip of the road to the south; one that is the building alone.
  def test_scoring_measures_building_pavement_and_road
    skip "no DuckDB CLI" unless Curtilage::DuckDB.version(Curtilage.config.duckdb)

    Dir.mktmpdir do |dir|
      write_region(dir)
      site = { "id" => "A", "group" => "clear", "building" => square(0, 0, 10), "parcel" => square(0, 0, 40) }
      rows = [site.merge("kind" => "wide", "premises" => rectangle(-50, -55, 50, 40), "store" => square(0, 0, 10),
                         "osm" => square(0, 0, 10), "access" => []),
              site.merge("kind" => "building", "premises" => square(0, 0, 10), "store" => nil, "osm" => nil,
                         "access" => [])]
      scores = B.regional_score("dc", rows, dir: dir).to_h { |r| [r["kind"], r] }

      assert_equal [1.0, 1.0, 1.0], scores["wide"].values_at("building_share", "store_iou", "pavement_share")
      assert_in_delta 100 * 8, scores["wide"]["road_m2"], 20 # 100 m of the strip, the road shrunk 2 m
      assert_equal [0, 0, 0, 0], scores["wide"].values_at("sidewalk_m2", "neighbour_m2", "neighbour_building_m2",
                                                          "neighbour_paving_m2")
      assert_equal [1.0, 0.0, 0], scores["building"].values_at("building_share", "pavement_share", "road_m2")
    end
  end

  def write_region(dir)
    layers = { "buildings" => [square(0, 0, 10), square(400, 0, 10), square(0, 2000, 10)].map { ["building", _1] },
               "parcels" => [square(0, 0, 40), square(400, 0, 40), square(0, 2000, 40),
                             square(1000, 1000, 40)].map { ["parcel", _1] },
               "roads" => [square(0, -25, 10), square(400, -25, 10), square(0, 1975, 10)].map { ["parking", _1] } +
                          [["road", rectangle(-200, -60, 600, -45)]],
               "sidewalks" => [] }
    layers.each do |name, rows|
      File.write(File.join(dir, "#{name}.ndjson"), rows.map { |c, g| "#{JSON.generate(class: c, geometry: g)}\n" }.join)
    end
    pins = { "A" => [0, 0], "B" => [400, 0], "C" => [0, 2000], "D" => [1000, 1000], "F" => [3000, 3000] }
    place = lambda do |id, (x, y)|
      JSON.generate(id: id, name: id, category: "pharmacy", lng: lnglat(x, y)[0], lat: lnglat(x, y)[1])
    end
    File.write(File.join(dir, "sites.ndjson"), pins.map { |id, xy| "#{place.call(id, xy)}\n" }.join)
    File.write(File.join(dir, "businesses.ndjson"), "#{place.call("X", [410, 5])}\n#{place.call("A", [0, 0])}\n")
  end

  # A site with everything in and nothing out, one leaking road, and one
  # whose OSM building disagrees with the official one (left out).
  def test_summary_counts_sites_passing_each_test
    good = { "kind" => "curtilage", "group" => "clear", "osm_iou" => 0.9, "building_share" => 1.0,
             "pavement_share" => 1.0, "area_m2" => 1000, "road_m2" => 0, "sidewalk_m2" => 0, "neighbour_m2" => 0,
             "structures" => [{ "class" => "canopy", "own" => true, "inside" => true }],
             "entrances" => 2, "entrances_found" => 1, "access_points" => 1, "access_right" => 1 }
    leaky = good.merge("road_m2" => 50, "structures" => [{ "class" => "building", "own" => false, "inside" => true }])
    row = B.regional_summary({ "sites" => [good, leaky, good.merge("osm_iou" => 0.2)] }).first

    assert_equal [2, 1], row.values_at("sites", "vintage")
    assert_equal [1.0, 0.5, 0.5], row.values_at("all_in", "nothing_out", "any_road_leak")
    assert_equal({ "canopy" => 1.0 }, row["own_structures_in"])
    assert_equal({ "building" => 1.0 }, row["other_structures_in"])
    assert_equal [0.5, 1.0], row.values_at("entrance_recall", "entrance_precision")
  end

  # Pages until the server stops saying there's more.
  def test_fetch_layer_pages_until_the_end
    pages = { 0 => [feature(1050, id: 1), feature(1070, id: 2)], 2 => [feature(9999, id: 3)] }
    out = StringIO.new
    offsets = with_pages(pages) { assert_equal [2, 1], B.fetch_layer(ROADS, out) }

    assert_equal [0, 2], offsets
    assert_equal(%w[road parking], out.string.lines.map { |l| JSON.parse(l)["class"] })
  end

  # A server that ignores the offset sends the first page again: stop.
  def test_fetch_layer_stops_on_a_repeated_page
    first = [feature(1050, id: 1), feature(1070, id: 2)]
    with_pages(Hash.new(first)) { assert_raises(RuntimeError) { B.fetch_layer(ROADS, StringIO.new) } }
  end

  # ArcGIS Online says there's more in properties; a full page means more too.
  def test_more_pages_from_either_marker_or_a_full_page
    two = [feature(1050), feature(1070)]

    assert B.more?({ "properties" => { "exceededTransferLimit" => true } }, two, 500)
    assert B.more?({}, two, 2)
    refute B.more?({}, two, 500)
    refute B.more?({ "exceededTransferLimit" => true }, [], 500)
  end

  # An answer over the size cap is asked for again with half the features.
  def test_oversized_pages_are_halved
    asked = []
    B.singleton_class.send(:alias_method, :real_arcgis_get, :arcgis_get)
    B.define_singleton_method(:arcgis_get) do |uri|
      size = URI.decode_www_form(uri.query).to_h.fetch("resultRecordCount").to_i
      asked << size
      raise B::AnswerTooBig, "too big" if size > 250

      { "features" => [] }
    end

    assert_equal 250, B.regional_page(ROADS, 0, 1000)[1]
    assert_equal [1000, 500, 250], asked
  ensure
    B.singleton_class.send(:alias_method, :arcgis_get, :real_arcgis_get)
  end

  # A passing server error is tried again; one that persists is raised.
  def test_server_errors_are_tried_again
    calls = 0
    B.singleton_class.send(:alias_method, :real_arcgis_get, :arcgis_get)
    B.define_singleton_method(:arcgis_get) do |_uri|
      calls += 1
      calls < 3 ? { "error" => { "code" => 504, "message" => "" } } : { "features" => [] }
    end
    with_retry_wait(0) { assert_equal [{ "features" => [] }, 1000], B.regional_page(ROADS, 0, 1000) }
    assert_equal 3, calls
    calls = -10
    with_retry_wait(0) { assert_raises(RuntimeError) { B.regional_page(ROADS, 0, 1000) } }
  ensure
    B.singleton_class.send(:alias_method, :arcgis_get, :real_arcgis_get)
  end

  def with_retry_wait(seconds)
    old = B::REGIONAL_RETRY_S
    B.send(:remove_const, :REGIONAL_RETRY_S)
    B.const_set(:REGIONAL_RETRY_S, seconds)
    yield
  ensure
    B.send(:remove_const, :REGIONAL_RETRY_S)
    B.const_set(:REGIONAL_RETRY_S, old)
  end

  # Runs the block with regional_page answering from pages (offset =>
  # features, more to come after offset 0); returns the offsets asked for.
  def with_pages(pages)
    offsets = []
    B.singleton_class.send(:alias_method, :real_regional_page, :regional_page)
    B.define_singleton_method(:regional_page) do |_layer, offset, page|
      offsets << offset
      [{ "features" => pages[offset], "exceededTransferLimit" => pages.default ? true : offset.zero? }, page]
    end
    yield
    offsets
  ensure
    B.singleton_class.send(:alias_method, :regional_page, :real_regional_page)
  end
end
