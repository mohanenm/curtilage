# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/runner"
require "stringio"

# Offline: the regional check's class mapping and paging, on made-up pages.
class BenchmarkRegionalTest < Minitest::Test
  B = CurtilageBenchmark
  ROADS = B::REGIONAL_LAYERS.fetch("dc").first
  SQUARE = { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 0]]] }.freeze

  def feature(code, geometry = SQUARE, owner: nil)
    { "geometry" => geometry, "properties" => { "FEATURECODE" => code, "ASRNAME" => owner }.compact }
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
  end

  # Pages until the server stops saying there's more.
  def test_fetch_layer_pages_until_the_end
    pages = { 0 => [feature(1050), feature(1070)], 2 => [feature(9999)] }
    offsets = []
    B.singleton_class.send(:alias_method, :real_regional_page, :regional_page)
    B.define_singleton_method(:regional_page) do |_layer, offset|
      offsets << offset
      { "features" => pages.fetch(offset), "exceededTransferLimit" => offset.zero? }
    end
    out = StringIO.new

    assert_equal 2, B.fetch_layer(ROADS, out)
    assert_equal [0, 2], offsets
    assert_equal(%w[road parking], out.string.lines.map { |l| JSON.parse(l)["class"] })
  ensure
    B.singleton_class.send(:alias_method, :regional_page, :real_regional_page)
  end
end
