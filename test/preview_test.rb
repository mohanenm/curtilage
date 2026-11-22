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
    assert_includes html, "not valid"
    assert_includes html, "about 54 spaces"
    refute_match(/(src|href)=|url\(|@import/, html)
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
end
