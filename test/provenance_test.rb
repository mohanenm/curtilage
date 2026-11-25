# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class ProvenanceTest < Minitest::Test
  include SyntheticScene

  def test_a_result_records_the_gem_options_and_map_data
    prov = Curtilage.generate(PIN, scene, grow_m: 25).provenance

    assert_equal Curtilage::VERSION, prov[:gem_version]
    assert_match(/\A\h{64}\z/, prov[:features_sha256])
    assert_equal 25, prov[:options][:grow_m]
    assert_equal 7, prov[:options][:precision]
    assert_equal Curtilage::Generator::DEFAULTS.keys.sort, prov[:options].keys.sort
  end

  def test_the_fingerprint_ignores_feature_order_and_key_style
    symbols = scene.map { |f| JSON.parse(JSON.generate(f), symbolize_names: true) }
    sha = ->(features) { Curtilage::Features.new(PIN, features).sha256 }

    assert_equal sha.call(scene), sha.call(scene.reverse)
    assert_equal sha.call(scene), sha.call(symbols)
    refute_equal sha.call(scene), sha.call(scene.first(3))
  end

  def test_the_same_inputs_give_byte_identical_output
    run = -> { Curtilage::Formats.write([Curtilage.generate(PIN, scene)], :geojson) }

    assert_equal run.call, run.call
    refute_includes run.call, Time.now.year.to_s, "output holds no timestamps"
  end

  def test_feature_order_never_changes_the_output
    # Two neighbours either side, so the order of cuts matters.
    features = scene + [polygon("building", 5, -40, -6, -25, 6), polygon("building", 6, 14, 10, 30, 25),
                        polygon("parking", 7, 11, -20, 40, -12)]
    expected = Curtilage::Formats.write([Curtilage.generate(PIN, features)], :geojson)

    20.times do |seed|
      shuffled = features.shuffle(random: Random.new(seed))

      assert_equal expected, Curtilage::Formats.write([Curtilage.generate(PIN, shuffled)], :geojson)
    end
  end

  def test_precision_sets_the_decimal_places
    r = Curtilage.generate(PIN, scene, precision: 5)
    coords = r.ring + r.store_ring + r.details[:building][:footprint]

    assert(coords.flatten.all? { |v| v == v.round(5) })
    refute(Curtilage.generate(PIN, scene).ring.flatten.all? { |v| v == v.round(5) })
    [4, 16, 6.5, nil].each do |bad|
      assert_raises(ArgumentError) { Curtilage.generate(PIN, scene, precision: bad) }
    end
  end

  def test_a_catalogue_result_names_its_extract_dates_and_footprints
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "east.json"),
                 JSON.generate(format: 1, region: "test/east", parquet: "east.parquet", bbox: [-85, 34, -80, 37],
                               source_dates: ["2026-11-20"], ml_footprints: "microsoft",
                               built_at: "2026-11-21T10:00:00Z"))
      cat = Curtilage::Catalogue.from_dir(dir)
      result = Curtilage.send(:generate_one, PIN, scene, cat.files_for(PIN), cat, {})

      assert_equal({ source: "geofabrik",
                     regions: [{ region: "test/east", extract_dates: ["2026-11-20"],
                                 ml_footprints: { source: "microsoft", fetched: "2026-11-21" } }] },
                   result.provenance[:data])
      row = Curtilage::Formats.parse_csv(Curtilage::Formats.write([result], :csv))[1]

      cols = %w[gem_version data_source data_release].map { |c| Curtilage::Formats::CSV_COLUMNS.index(c) }

      assert_equal %W[#{Curtilage::VERSION} geofabrik 2026-11-20], row.values_at(*cols)
    end
  end

  def test_an_overture_result_names_the_release_it_read
    features = scene
    with_stub(Curtilage::Overture, :release, ->(_) { "2026-11-18.0" }) do
      with_stub(Curtilage::Overture, :features_many, ->(pins, **opts) { pins.map { features } if opts[:release] }) do
        result = Curtilage.send(:from_overture, [PIN], {}, {}, {}).first

        assert_equal({ source: "overture", release: "2026-11-18.0" }, result.provenance[:data])
        assert_includes Curtilage::Formats.write([result], :kml), "data: overture 2026-11-18.0"
      end
    end
  end

  def test_provenance_is_in_the_geojson
    doc = JSON.parse(Curtilage::Formats.write([Curtilage.generate(PIN, scene)], :geojson))
    props = doc["features"][0]["properties"]

    assert_equal Curtilage::VERSION, props["provenance"]["gem_version"]
    assert_equal "osm", props["provenance"]["options"]["buildings"]
  end
end
