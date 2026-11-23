# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class FormatsTest < Minitest::Test
  include SyntheticScene

  F = Curtilage::Formats

  def results
    [Curtilage.generate(PIN, scene), Curtilage.generate(PIN, [])]
  end

  def test_csv_pins_with_quotes_ids_and_blank_lines
    text = "﻿Name,Latitude,Longitude\r\n\"Store, \"\"North\"\"\",35.5,-80.25\r\n\r\n,35.6,-80.3\n"
    sites = F.parse_pins(text.delete_prefix("﻿"), :csv)

    assert_equal [{ id: 'Store, "North"', pin: [-80.25, 35.5] }, { id: "2", pin: [-80.3, 35.6] }], sites
  end

  def test_csv_needs_lng_and_lat
    error = assert_raises(ArgumentError) { F.parse_pins("id,x1,y1\n1,2,3\n", :csv) }
    assert_match(/lng and lat/, error.message)
    assert_raises(ArgumentError) { F.parse_pins("lng,lat\nabc,35\n", :csv) }
    assert_raises(ArgumentError) { F.parse_pins("lng,lat\n\"-80,35\n", :csv) }
  end

  def test_geojson_pins
    doc = { type: "FeatureCollection", features: [
      { type: "Feature", id: "s1", geometry: { type: "Point", coordinates: [-80.1, 35.1] }, properties: {} },
      { type: "Feature", geometry: { type: "Point", coordinates: [-80.2, 35.2, 100] }, properties: { name: "B" } },
    ] }

    assert_equal [{ id: "s1", pin: [-80.1, 35.1] }, { id: "B", pin: [-80.2, 35.2] }],
                 F.parse_pins(JSON.generate(doc), :geojson)
    assert_raises(ArgumentError) { F.parse_pins('{"type":"Feature","geometry":{"type":"LineString"}}', :geojson) }
    assert_raises(ArgumentError) { F.parse_pins("[1, 2]", :geojson) }
    assert_raises(ArgumentError) { F.parse_pins("{nope", :geojson) }
  end

  def test_read_pins_by_extension
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sites.csv")
      File.write(path, "lng,lat\n-80,35\n")

      assert_equal [{ id: "1", pin: [-80.0, 35.0] }], F.read_pins(path)
      assert_raises(ArgumentError) { F.read_pins(File.join(dir, "sites.txt")) }
    end
  end

  def test_geojson_output_is_one_collection
    doc = JSON.parse(F.write(results, :geojson, ids: %w[a b]))

    assert_equal "FeatureCollection", doc["type"]
    assert_equal(%w[a a b b], doc["features"].map { |f| f["properties"]["id"] })
    assert_equal 2, JSON.parse(F.write(results, :geojson, store: false))["features"].size
  end

  def test_csv_output
    rows = F.parse_csv(F.write(results, :csv, ids: ["=cmd", "b"]))

    assert_equal F::CSV_COLUMNS, rows[0]
    assert_equal "'=cmd", rows[1][0]
    assert_equal "true", rows[1][3]
    assert_match(/\APOLYGON/, rows[1][F::CSV_COLUMNS.index("premises_wkt")])
    assert_equal "false", rows[2][3]
    assert_equal "-80.0", rows[1][1]
    assert_equal "© OpenStreetMap contributors", rows[1][F::CSV_COLUMNS.index("attribution")]
  end

  def test_kml_output
    kml = F.write(results, :kml, ids: ["<a>", "b"])

    assert_includes kml, "<name>&lt;a&gt; premises</name>"
    assert_includes kml, "<name>&lt;a&gt; store</name>"
    refute_includes kml, "<name>b premises</name>"
    assert_equal 2, kml.scan("<Polygon>").size
    assert_includes kml, "<description>Map data: © OpenStreetMap contributors</description>"
  end

  def test_every_output_credits_each_source
    credited = Curtilage.generate(PIN, scene).tap { |r| r.attribution = ["© OpenStreetMap contributors", "<Odd> & Co"] }

    assert_includes F.write([credited], :csv), "© OpenStreetMap contributors; <Odd> & Co"
    assert_includes F.write([credited], :kml), "Map data: © OpenStreetMap contributors; &lt;Odd&gt; &amp; Co"
    assert_includes F.write([credited], :geojson), "<Odd> & Co"
    assert_includes Curtilage::Preview.html([credited]), "&lt;Odd&gt; &amp; Co"
  end

  def test_format_of
    assert_equal :kml, F.format_of("out.KML")
    assert_equal :geojson, F.format_of("a.json")
    assert_nil F.format_of(nil)
    assert_raises(ArgumentError) { F.write(results, :xlsx) }
  end

  def test_pin_range
    assert F.pin?([-80, 35])
    refute F.pin?([35, -120])
  end
end
