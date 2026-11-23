# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class PreviewTest < Minitest::Test
  include SyntheticScene

  def test_page_draws_each_site_and_loads_nothing
    results = [Curtilage.generate(PIN, scene), Curtilage.generate(PIN, [])]
    html = Curtilage::Preview.html(results, ids: ["<b>one</b>", "two"])

    assert_equal 2, html.scan("<svg ").size
    assert_includes html, "&lt;b&gt;one&lt;/b&gt;"
    refute_includes html, "<b>one</b>"
    assert_includes html, %(class="premises")
    assert_includes html, %(class="building")
    assert_includes html, "no premises: no building within 30 m of the pin (it may be missing from OpenStreetMap"
    assert_includes html, "about 54 spaces"
    refute_match(/(src|href)=|url\(|@import/, html)
  end

  def test_entrances_buffer_site_building_and_flag_help
    drive = scene + [road(9, "service", [[-30, -15], [-30, -40]])]
    result = Curtilage.generate(PIN, drive).tap { |r| r.flags << :near_houses }
    html = Curtilage::Preview.html([result], buffer_m: 10)

    assert_equal 1, html.scan(%(class="access")).size
    assert_includes html, %(class="buffer")
    assert_includes html, "premises + 10 m"
    assert_includes html, %(class="building site")
    assert_includes html, %(title="The lot borders a home)
    assert_includes html, "1 site(s): 0 ok, 1 ok but flagged for a look, 0 without usable premises"
    assert_includes html, %(data-state="flagged")
    assert_includes html, %(data-flags="near_houses")
    assert_includes html, %(<option value="flag:near_houses">Flag near_houses (1)</option>)
    assert_includes html, %(<option value="look">Needs a look first</option>)
  end

  def test_without_features_only_the_premises_are_drawn
    result = Curtilage.generate(PIN, scene).tap { |r| r.features = nil }
    html = Curtilage::Preview.html([result])

    assert_includes html, %(class="premises")
    refute_includes html, %(class="building")
  end

  def test_cli_reads_a_file_and_reports_bad_input
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "pins.csv")
      File.write(path, "id,lat,lng\nx,-120,35\n")
      _, err, status = Open3.capture3("ruby", "-I", lib, exe, "preview", "--in", path)

      refute_predicate status, :success?
      assert_includes err, "x: a pin is LNG,LAT"
      _, err, = Open3.capture3("ruby", "-I", lib, exe, "generate", "--in", File.join(dir, "missing.csv"))

      assert_includes err, "No such file"
    end
  end

  # A fake DuckDB that finds nothing: runs the whole command line, offline.
  def test_cli_writes_each_format_and_the_page
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      File.write(File.join(dir, "pins.csv"), "id,lng,lat\nshop-1,-80.0,35.0\n")
      args = ["--in", File.join(dir, "pins.csv"), "--parquet", File.join(dir, "region.parquet"), "--duckdb", fake]
      run = ->(*extra) { Open3.capture3("ruby", "-I", lib, exe, *extra, *args) }

      _, err, status = run.call("generate", "--out", File.join(dir, "out.csv"))

      assert_equal 1, status.exitstatus # nothing usable: no map data
      assert_includes err, "0 of 1 ok"
      rows = Curtilage::Formats.parse_csv(File.read(File.join(dir, "out.csv"), encoding: "utf-8"))

      assert_equal %w[shop-1 false], rows[1].values_at(0, 3)
      out, = run.call("generate", "--format", "kml")

      assert_includes out, "<kml"
      _, _, status = run.call("preview", "--out", File.join(dir, "page.html"))

      assert_predicate status, :success?
      assert_includes File.read(File.join(dir, "page.html")), "shop-1"
    end
  end
end
