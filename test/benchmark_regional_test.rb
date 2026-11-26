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
  # another business; C is 100 m from a held-out site; D is on no building.
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

  def write_region(dir)
    layers = { "buildings" => [square(0, 0, 10), square(400, 0, 10), square(0, 2000, 10)].map { ["building", _1] },
               "parcels" => [square(0, 0, 40), square(400, 0, 40), square(0, 2000, 40)].map { ["parcel", _1] },
               "roads" => [square(0, -25, 10), square(400, -25, 10), square(0, 1975, 10)].map { ["parking", _1] },
               "sidewalks" => [] }
    layers.each do |name, rows|
      File.write(File.join(dir, "#{name}.ndjson"), rows.map { |c, g| "#{JSON.generate(class: c, geometry: g)}\n" }.join)
    end
    pins = { "A" => [0, 0], "B" => [400, 0], "C" => [0, 2000], "D" => [1000, 1000] }
    place = lambda do |id, (x, y)|
      JSON.generate(id: id, name: id, category: "pharmacy", lng: lnglat(x, y)[0], lat: lnglat(x, y)[1])
    end
    File.write(File.join(dir, "sites.ndjson"), pins.map { |id, xy| "#{place.call(id, xy)}\n" }.join)
    File.write(File.join(dir, "businesses.ndjson"), "#{place.call("X", [410, 5])}\n#{place.call("A", [0, 0])}\n")
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

  # Runs the block with regional_page answering from pages (offset =>
  # features, more to come after offset 0); returns the offsets asked for.
  def with_pages(pages)
    offsets = []
    B.singleton_class.send(:alias_method, :real_regional_page, :regional_page)
    B.define_singleton_method(:regional_page) do |_layer, offset|
      offsets << offset
      { "features" => pages[offset], "exceededTransferLimit" => true }.tap do |doc|
        doc["exceededTransferLimit"] = offset.zero? unless pages.default
      end
    end
    yield
    offsets
  ensure
    B.singleton_class.send(:alias_method, :regional_page, :real_regional_page)
  end
end
