# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class PlacesTest < Minitest::Test
  O = Curtilage::Overture
  F = Curtilage::Formats
  ROW = { "id" => "p1", "name" => "Corner\u0007 Pharmacy", "brand" => nil, "category" => "pharmacy",
          "confidence" => 0.934, "sources" => %w[meta Overture], "licences" => ["CDLA-Permissive-2.0"],
          "lng" => -80.001, "lat" => 35.002 }.freeze

  def test_filters_become_quoted_sql
    assert_equal "(list_contains(taxonomy.hierarchy, 'pharmacy') OR basic_category = 'pharmacy')",
                 O.place_filter("pharmacy", nil, nil)
    assert_equal "lower(brand.names.\"primary\") = lower('O''Brien''s')", O.place_filter(nil, "O'Brien's", nil)
    assert_equal "id IN ('a', 'b')", O.place_filter(nil, nil, %w[a b])
    [[nil, nil, nil], ["pharmacy", "CVS", nil], ["x\ny", nil, nil], ["x" * 201, nil, nil],
     [nil, nil, []]].each do |args|
      assert_raises(ArgumentError) { O.place_filter(*args) }
    end
  end

  def test_boxes_are_checked
    assert_equal [-81.0, 34.0, -79.0, 36.0], O.checked_bbox(["-81", 34, -79, "36"])
    [[1, 2, 3], [-79, 34, -81, 36], [-81, 34, -79, 95], [-130, 20, -60, 50], ["0x1", 34, -79, 36]].each do |box|
      assert_raises(ArgumentError) { O.checked_bbox(box) }
    end
  end

  def test_the_query_leaves_out_closed_places_and_caps_rows
    sql = O.places_sql(["s3://overturemaps-us-west-2/x.parquet"], [-81, 34, -79, 36], "id IN ('a')", 10, {})

    assert_includes sql, "NOT IN ('permanently_closed', 'temporarily_closed')"
    assert_includes sql, "LIMIT 11;"
    assert_includes sql, "id IN ('a')"
  end

  def test_rows_are_cleaned_like_map_text
    place = O.place(ROW)

    assert_equal "Corner Pharmacy", place[:name]
    assert_equal [-80.001, 35.002], place[:pin]
    assert_in_delta 0.93, place[:confidence]
    assert_raises(ArgumentError) { O.place(ROW.merge("lat" => 95)) }
  end

  def with_fake_overture(rows)
    with_stub(O, :release, ->(_) { "2026-11-18.0" }) do
      with_stub(Curtilage::Download, :read, ->(*, **) { "" }) do
        answers = [
          [{ "href" => "s3://overturemaps-us-west-2/x.parquet" }, { "href" => "https://elsewhere" },
           { "href" => "s3://overturemaps-elsewhere/x.parquet" }], rows
        ]
        seen = []
        with_stub(O, :run, lambda { |sql, _|
          seen << sql
          answers.shift
        }) { yield seen }
      end
    end
  end

  def test_places_reads_only_overture_files_and_refuses_too_many
    with_fake_overture([ROW, ROW.merge("id" => "p2")]) do |seen|
      found = O.places(bbox: [-81, 34, -79, 36], category: "pharmacy", min_confidence: 0.5)

      assert_equal(%w[p1 p2], found.map { |p| p[:id] })
      refute_includes seen.last, "elsewhere"
      assert_includes seen.last, "confidence >= 0.5"
    end
    with_fake_overture([ROW, ROW]) do
      assert_raises(ArgumentError) { O.places(bbox: [-81, 34, -79, 36], brand: "x", max: 1) }
    end
  end

  def test_a_region_keeps_only_places_inside_its_outline
    outline = [[-81, 34], [-80, 34], [-80, 36], [-81, 36], [-81, 34]]
    shp = "https://download.geofabrik.de/north-america/us/test-latest-free.shp.zip"
    index = JSON.generate(features: [{ properties: { id: "t", urls: { shp: shp } },
                                       geometry: { type: "Polygon", coordinates: [outline] } }])
    inside = ROW
    outside = ROW.merge("id" => "far", "lng" => -79.5)
    with_stub(Curtilage::Regions, :download, -> { Curtilage::Regions.parse(index) }) do
      with_fake_overture([inside, outside]) do
        assert_equal(%w[p1], Curtilage.places(region: "test", category: "pharmacy").map { |p| p[:id] })
      end
    end
    assert_raises(ArgumentError) { Curtilage.places(region: "test", bbox: [-81, 34, -79, 36], category: "x") }
  end

  def test_places_write_as_pins_that_read_back
    places = [O.place(ROW)]
    csv = F.write_places(places, :csv)

    assert_equal F::PLACE_COLUMNS, F.parse_csv(csv)[0]
    %i[csv ndjson geojson].each do |format|
      assert_equal [{ id: "p1", pin: [-80.001, 35.002] }], F.parse_pins(F.write_places(places, format), format)
    end
    assert_includes F.write_places([O.place(ROW.merge("name" => "=cmd"))], :csv), "'=cmd"
  end

  def test_cli_contract
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    run = ->(*args, env: {}) { Open3.capture3(env, "ruby", "-I", lib, exe, "places", *args) }

    _, err, status = run.call("--bbox", "-81,34,-79,36", "--category", "a", "--brand", "b")

    assert_equal [2, true], [status.exitstatus, err.include?("give one of")]
    _, err, status = run.call("--bbox", "-81,34,-79,36", "--category", "a", env: { "CURTILAGE_OFFLINE" => "1" })

    assert_equal [4, true], [status.exitstatus, err.include?("offline mode")]
  end
end
