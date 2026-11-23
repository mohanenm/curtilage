# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require "tmpdir"

# The DuckDB runner, driven by fake CLIs (POSIX sh, as on CI's dash).
class DuckDBTest < Minitest::Test
  D = Curtilage::DuckDB

  def fake(dir, body)
    path = File.join(dir, "duckdb")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # A query that hangs is stopped, child processes included, and the
  # caller gets an error instead of waiting forever.
  def test_a_hung_query_is_stopped_with_its_children
    Dir.mktmpdir do |dir|
      cli = fake(dir, "sleep 30 &\nprintf '%s' \"$!\" > \"$(dirname \"$0\")/child\"\nsleep 30")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Curtilage::Error) { D.capture(cli, "SELECT 1;", timeout: 0.5) }

      assert_includes error.message, "took over 0.5 s"
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
      child = Integer(File.read(File.join(dir, "child")))
      sleep 0.2
      refute alive?(child), "the child process should be stopped too"
    end
  end

  # Ctrl-C reaches Ruby but not DuckDB (it has its own process group), so
  # an interrupted caller must stop it rather than wait for it.
  def test_an_interrupted_caller_stops_duckdb
    Dir.mktmpdir do |dir|
      cli = fake(dir, "sleep 30 &\nprintf '%s' \"$!\" > \"$(dirname \"$0\")/child\"\nsleep 30")
      caller = Thread.new { D.capture(cli, "SELECT 1;", timeout: 60) }
      caller.report_on_exception = false
      sleep 0.1 until File.exist?(File.join(dir, "child"))
      caller.raise(Interrupt)

      assert_raises(Interrupt) { Timeout.timeout(5) { caller.join } }
      sleep 0.2
      refute alive?(Integer(File.read(File.join(dir, "child")))), "DuckDB's children should be stopped"
    end
  end

  def test_runaway_output_is_cut_off
    Dir.mktmpdir do |dir|
      cli = fake(dir, "while :; do printf '%s\\n' xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done")
      error = assert_raises(Curtilage::Error) { D.capture(cli, "", timeout: 10, max_output: 100_000) }

      assert_includes error.message, "passed 100000 bytes"
    end
  end

  def test_a_cli_that_ignores_its_input_is_fine
    Dir.mktmpdir do |dir|
      cli = fake(dir, "printf '[]\\n'")
      out, _, status = D.capture(cli, "SELECT 1;\n" * 200_000, timeout: 10)

      assert_predicate status, :success?
      assert_equal "[]\n", out
    end
  end

  # The query excerpt DuckDB quotes in an error can hold a pin's box.
  def test_errors_lose_the_quoted_query
    Dir.mktmpdir do |dir|
      excerpt = "LINE 1: ... WHERE max_lng >= -80.004 AND min_lng <= -79.996"
      message = "Binder Error: no such column\\n\\n#{excerpt}\\n#{" " * 20}^\\n"
      cli = fake(dir, "cat > /dev/null\nprintf '#{message}' >&2\nexit 1")
      File.write(File.join(dir, "a.parquet"), "")
      error = assert_raises(Curtilage::Error) do
        Curtilage::Lookup.features(parquet: File.join(dir, "a.parquet"), pin: [-80.0, 35.0], duckdb: cli)
      end

      assert_includes error.message, "Binder Error: no such column"
      refute_includes error.message, "-80.004"
    end
  end

  def test_lookups_cap_duckdb_memory
    sql = Curtilage::Lookup.sql(["x.parquet"], [[-80.0, 35.0]], nil, 0.004)

    assert_includes sql, "SET memory_limit = '1GB';"
    assert_includes Curtilage::Lookup.sql(["x.parquet"], [[-80.0, 35.0]], nil, 0.004, memory_limit: "3GB"), "'3GB'"
    assert_includes Curtilage::Overture.setup({}, remote: false), "SET memory_limit = '1GB';"
  end

  def test_timeout_setting_must_be_seconds
    assert_raises(ArgumentError) { Curtilage.seconds("soon") }
    assert_raises(ArgumentError) { Curtilage.seconds("-1") }
    assert_in_delta 90.0, Curtilage.seconds("90")
  end
end
