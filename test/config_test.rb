# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class ConfigTest < Minitest::Test
  def teardown
    Curtilage.reset_config!
  end

  def test_environment_defaults_and_configure
    assert_equal :auto, Curtilage.config.source
    Curtilage.configure do |c|
      c.duckdb = "/opt/duckdb"
      c.source = :overture
    end

    assert_equal "/opt/duckdb", Curtilage.duckdb_options[:duckdb]
    assert_equal "/x/duckdb", Curtilage.duckdb_options(duckdb: "/x/duckdb")[:duckdb]
    assert_equal :overture, Curtilage.config.source
  end

  # premises picks its data source from the configuration; with no data at
  # all for a pin, the result says so instead of raising.
  def test_premises_without_data_is_flagged
    Dir.mktmpdir do |dir|
      catalogue = Curtilage::Catalogue.from_dir(dir)
      result = Curtilage.premises([-80.0, 35.0], catalogue: catalogue)

      refute_predicate result, :ok?
      assert_includes result.flags, :no_data
    end
  end

  # A fake DuckDB that exits silently on its first call and answers on the
  # second: the stalled-read case.
  def test_overture_retries_a_silent_failure_once
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, <<~SH)
        #!/bin/sh
        calls="$(dirname "$0")/calls"
        n=$(( $(cat "$calls" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$calls"
        cat > /dev/null
        [ "$n" -eq 1 ] && exit 1
        echo "[]"
      SH
      File.chmod(0o755, fake)

      assert_equal [], Curtilage::Overture.run("SELECT 1;", { duckdb: fake })
      assert_equal "2", File.read(File.join(dir, "calls")).strip
    end
  end

  def test_cli_help_and_usage
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    out, = Open3.capture2("ruby", "-I", lib, exe, "--help")

    assert_includes out, "curtilage generate (--pin LNG,LAT ... | --in FILE)"
    assert_includes out, "curtilage preview"
    _, err, status = Open3.capture3("ruby", "-I", lib, exe, "generate")

    refute_predicate status, :success?
    assert_includes err, "give --pin LNG,LAT or --in FILE"
  end
end
