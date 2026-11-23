# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

# The command line's contract: exit codes, and nothing but results on
# standard output.
class CliTest < Minitest::Test
  EXE = File.expand_path("../exe/curtilage", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  def cli(*, env: {}, stdin: "")
    out, err, status = Open3.capture3(env, "ruby", "-I", LIB, EXE, *, stdin_data: stdin)
    [out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8), status]
  end

  # A fake DuckDB that returns no map data, and a pin file.
  def with_setup
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\necho '[]'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "region.parquet"), "")
      yield dir, ["--parquet", File.join(dir, "region.parquet"), "--duckdb", fake, "--pin", "-80,35"]
    end
  end

  def test_bad_input_and_usage_exit_two
    [%w[generate], %w[generate --pin 95,-80,1], %w[generate --nope], %w[frobnicate], %w[build],
     %w[generate --in missing.csv], %w[generate --format pdf --pin -80,35],
     %w[generate --entrances some --pin -80,35]].each do |args|
      _, err, status = cli(*args)

      assert_equal 2, status.exitstatus, "#{args.join(" ")}: #{err}"
      refute_includes err, ".rb:", "no stack trace"
    end
  end

  def test_missing_duckdb_exits_three
    with_setup do |dir, args|
      _, err, status = cli("generate", *args, "--duckdb", File.join(dir, "no-such-duckdb"))

      assert_equal 3, status.exitstatus
      assert_includes err, "DuckDB CLI not found"
    end
  end

  def test_unavailable_data_exits_four
    _, err, status = cli("generate", "--pin", "-80,35", "--source", "overture", env: { "CURTILAGE_OFFLINE" => "1" })

    assert_equal 4, status.exitstatus
    assert_includes err, "offline mode"
  end

  def test_entrances_flag_is_accepted
    with_setup do |_, args|
      _, err, status = cli("generate", *args, "--entrances", "all", "--format", "ndjson")

      assert_equal 1, status.exitstatus, err # no map data, but no usage error
    end
  end

  def test_results_alone_on_standard_output
    with_setup do |_, args|
      out, err, status = cli("generate", *args, "--format", "ndjson")

      assert_equal 1, status.exitstatus # no map data, so no premises
      assert_equal 1, out.lines.size
      refute JSON.parse(out)["properties"]["ok"]
      assert_empty err
    end
  end

  def test_quiet_and_json_logs
    with_setup do |dir, args|
      out_file = File.join(dir, "out.ndjson")
      _, err, = cli("generate", *args, "--out", out_file, "--quiet")

      assert_empty err
      _, err, = cli("generate", *args, "--out", out_file, "--log-format", "json")

      assert_equal({ "level" => "info", "message" => "0 of 1 ok; wrote #{out_file}" }, JSON.parse(err))
      _, err, = cli("generate", "--log-format", "json")

      assert_equal "error", JSON.parse(err)["level"]
    end
  end

  def test_warnings_survive_quiet
    # The CLI's logger alone (the script itself runs a command when loaded).
    eval(File.read(EXE)[/^class CliLog.*?^end$/m], binding, EXE) # rubocop:disable Security/Eval
    levels = [{ quiet: true }, {}].map do |opts|
      log = CliLog.new
      log.configure(opts.merge(log_format: "json"))
      _, err = capture_io do
        log.puts("building x")
        log.puts("warning: changed upstream")
      end
      err.lines.map { |l| JSON.parse(l)["level"] }
    end

    assert_equal [%w[warning], %w[info warning]], levels
  end
end
