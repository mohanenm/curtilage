# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "stringio"
require "tmpdir"

class BatchTest < Minitest::Test
  include SyntheticScene

  B = Curtilage::Batch
  F = Curtilage::Formats

  def results = [PIN, lnglat(1, 1), lnglat(-1, 2)].map { |p| Curtilage.generate(p, scene) }
  def ids = %w[a b c]

  def test_streamed_chunks_equal_one_write
    %i[ndjson csv].each do |format|
      Dir.mktmpdir do |dir|
        out = File.join(dir, "out.#{format}")
        batch = B.new(format: format, out: out)
        batch.add(results.first(2), ids.first(2))

        assert_path_exists batch.part, "rows go to the .part file as they're made"
        refute_path_exists out
        batch.add(results.drop(2), ids.drop(2))
        batch.finish

        assert_equal F.write(results, format, ids: ids), File.read(out, encoding: "utf-8")
        refute_path_exists batch.part
      end
    end
  end

  def test_resume_skips_finished_sites_and_a_cut_off_line
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out.ndjson")
      first = B.new(format: :ndjson, out: out)
      first.add(results.first(2), ids.first(2))
      File.open(first.part, "a") { |f| f.write('{"type":"Feature","prop') } # the crash
      again = B.new(format: :ndjson, out: out, resume: true)

      assert_equal Set["a", "b"], again.done
      again.add(results.drop(2), ids.drop(2))
      again.finish

      assert_equal F.write(results, :ndjson, ids: ids), File.read(out, encoding: "utf-8")
    end
  end

  def test_resume_needs_a_streamed_file
    assert_raises(ArgumentError) { B.new(format: :ndjson, resume: true) }
    assert_raises(ArgumentError) { B.new(format: :geojson, out: "x.geojson", resume: true) }
  end

  def test_documents_are_written_whole
    batch = B.new(format: :geojson, out: "unused.geojson")
    batch.add(results.first(1), ids.first(1))
    batch.add(results.drop(1), ids.drop(1))
    written = nil
    batch.finish { |text| written = text }

    assert_equal F.write(results, :geojson, ids: ids), written
  end

  def test_standard_output_streams_too
    io = StringIO.new
    batch = B.new(format: :csv, output: io)
    batch.add(results.first(1), ids.first(1))
    batch.add(results.drop(1), ids.drop(1))
    batch.finish

    assert_equal F.write(results, :csv, ids: ids), io.string
  end

  def test_progress_shows_rate_and_time_left
    io = StringIO.new
    now = 0
    progress = B::Progress.new(1_000, output: io, clock: -> { now })
    now = 10
    progress.step(250)

    assert_includes io.string, "250/1000 sites (25%), 25.0/s, about 0:30 left"
  end

  def test_the_cli_resumes
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      out = File.join(dir, "out.ndjson")
      args = ["--pin", "-80,35", "--pin", "-80.1,35", "--pin", "-80.2,35", "--parquet",
              File.join(dir, "region.parquet"), "--duckdb", fake, "--out", out]
      File.write(File.join(dir, ".out.ndjson.part"),
                 F.write([Curtilage.generate(PIN, [])], :ndjson, ids: ["2"]))
      _, err, = Open3.capture3("ruby", "-I", lib, exe, "generate", *args, "--resume")
      lines = File.readlines(out, encoding: "utf-8").map { |l| JSON.parse(l)["properties"]["id"] }

      assert_equal %w[2 1 3], lines
      assert_includes err, "0 of 2 ok"
      File.write(File.join(dir, "twice.csv"), "id,lng,lat\nx,-80,35\nx,-80.1,35\n")
      _, err, status = Open3.capture3("ruby", "-I", lib, exe, "generate", "--in", File.join(dir, "twice.csv"),
                                      "--out", out, "--resume")

      assert_equal 2, status.exitstatus
      assert_includes err, "unique site ids"
    end
  end

  # GeoParquet, GeoPackage and FlatGeobuf are files written at the end.
  def test_gis_formats_need_a_file
    assert_raises(ArgumentError) { Curtilage::Batch.new(format: :gpkg) }
    assert_raises(ArgumentError) { Curtilage::Formats.write([], :fgb) }
    assert_equal :geoparquet, Curtilage::Formats.format_of("out.parquet")
    assert_equal :gpkg, Curtilage::Formats.format_of("OUT.GPKG")
    assert_equal :fgb, Curtilage::Formats.format_of("out.fgb")
    sql = Curtilage::GisFormats.copy_sql("in.ndjson", "out.fgb", :fgb)

    assert_includes sql, "WHERE json_type(geometry) = 'OBJECT'"
    refute_includes Curtilage::GisFormats.copy_sql("in.ndjson", "out.gpkg", :gpkg), "WHERE"
  end
end
