# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

class DiffTest < Minitest::Test
  include SyntheticScene

  D = Curtilage::Diff

  def read(results, ids)
    Curtilage::Formats.parse_results(Curtilage::Formats.write(results, :ndjson, ids: ids), :ndjson)
  end

  def test_the_same_run_needs_no_review
    run = read([Curtilage.generate(PIN, scene)], ["a"])
    rows = D.compare(run, run)

    assert_equal([["a", "same", false]], rows.map { |r| r.values_at(:id, :status, :review) })
    assert_in_delta 1.0, rows[0][:iou]
  end

  def test_small_and_large_changes
    old = read([Curtilage.generate(PIN, scene)], ["a"])
    nudged = read([Curtilage.generate(PIN, scene, grow_m: 28)], ["a"])
    tight = read([Curtilage.generate(PIN, scene, preset: :tight)], ["a"])

    small = D.compare(old, nudged).first

    assert_equal "changed", small[:status]
    refute small[:review], "IoU #{small[:iou]} is above 0.9"
    big = D.compare(old, tight).first

    assert big[:review]
    assert_operator big[:area_change_pct], :<, -50
    assert D.compare(old, nudged, threshold: 0.999).first[:review]
  end

  def test_flags_ok_and_sites_coming_and_going
    old = read([Curtilage.generate(PIN, scene)], ["a"])
    houses = read([Curtilage.generate(PIN, scene + [polygon("building", 5, 25, -6, 35, 6, type: "house")])], ["a"])
    gone = read([Curtilage.generate([-80.01, 35.01], scene)], ["a"])
    row = D.compare(old, houses).first

    assert_equal [true, ["near_houses"]], row.values_at(:review, :flags_gained)
    assert_equal [true, false], D.compare(old, gone).first.values_at(:review, :ok_new)
    assert_equal({ "a" => "removed", "b" => "added" },
                 D.compare(old, read([Curtilage.generate(PIN, scene)], ["b"])).to_h { |r| [r[:id], r[:status]] })
  end

  def test_the_cli_writes_a_report_and_exits_one_when_review_is_needed
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.ndjson")
      b = File.join(dir, "b.geojson")
      File.write(a, Curtilage::Formats.write([Curtilage.generate(PIN, scene)], :ndjson, ids: ["s"]))
      File.write(b, Curtilage::Formats.write([Curtilage.generate(PIN, scene, preset: :tight)], :geojson, ids: ["s"]))
      out, err, status = Open3.capture3("ruby", "-I", lib, exe, "diff", a, b)
      rows = Curtilage::Formats.parse_csv(out)

      assert_equal D::COLUMNS, rows[0]
      assert_equal %w[s changed true], rows[1].first(3)
      assert_equal 1, status.exitstatus
      assert_includes err, "1 to review"
      _, _, status = Open3.capture3("ruby", "-I", lib, exe, "diff", a, a)

      assert_equal 0, status.exitstatus
      _, _, status = Open3.capture3("ruby", "-I", lib, exe, "diff", a)

      assert_equal 2, status.exitstatus
    end
  end
end
