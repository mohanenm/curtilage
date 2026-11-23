# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class LookupTest < Minitest::Test
  L = Curtilage::Lookup

  def test_local_files_join_the_pins_boxes_and_quote_paths
    sql = L.sql(["/tmp/it's.parquet"], [[-80.0, 35.0], [-81.0, 36.0]], "/ext", 0.004)

    assert_includes sql, "read_parquet(['/tmp/it''s.parquet']) f JOIN boxes b"
    assert_includes sql, "SET extension_directory = '/ext';"
    assert_includes sql, "(1, -81.004, 35.996, -80.996, 36.004)"
    assert_includes sql, "f.max_lng >= b.x0 AND f.min_lng <= b.x1"
    refute_includes sql, "httpfs"
  end

  # Remote files keep a scan per pin, so only the row groups near each pin
  # are read, not whole files.
  def test_remote_files_scan_per_pin_load_httpfs_and_take_setup_sql
    sql = L.sql(["s3://bucket/tennessee.parquet"], [[-80.0, 35.0], [-81.0, 36.0]], nil, 0.004,
                "CREATE SECRET (TYPE s3);")

    assert_includes sql, "LOAD httpfs;"
    assert_includes sql, "CREATE SECRET (TYPE s3);"
    assert_includes sql, "SELECT 1 AS pin_index"
    assert_includes sql, "max_lng >= -81.004 AND min_lng <= -80.996"
    refute_includes sql, "JOIN boxes"
  end

  def test_rejects_bad_pins_and_radius
    [[nil, 35.0], nil, [1], "-80,35"].each { |pin| assert_raises(ArgumentError) { L.checked(pin) } }
    assert_raises(ArgumentError) { L.sql(["x"], [[-80.0, 135.0]], nil, 0.004) }
    assert_raises(ArgumentError) { L.sql(["x"], [["1; DROP", 35.0]], nil, 0.004) }
    assert_raises(ArgumentError) { L.sql(["x"], [[-80.0, 35.0]], nil, 1) }
  end

  # DuckDB refuses a UNION ALL of more than about 1,000 scans: big batches
  # are split across calls, and results stay in pin order.
  def test_large_batches_take_several_calls
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, <<~SH)
        #!/bin/sh
        echo x >> "$(dirname "$0")/calls"
        cat > /dev/null
        printf '%s\n' '[{"pin_index": 0, "id": 1, "geometry": "{\\"type\\":\\"Point\\",\\"coordinates\\":[0,0]}"}]'
      SH
      File.chmod(0o755, fake)
      File.write(File.join(dir, "a.parquet"), "")
      lists = L.features_many(parquet: File.join(dir, "a.parquet"), pins: Array.new(1_200) { [-80.0, 35.0] },
                              duckdb: fake)

      assert_equal 3, File.readlines(File.join(dir, "calls")).size
      assert_equal 1_200, lists.size
      assert_equal([0, 500, 1000], lists.each_index.reject { |i| lists[i].empty? })
    end
  end

  def test_non_ascii_names_parse_whatever_the_locale
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, <<~SH)
        #!/bin/sh
        cat > /dev/null
        printf '%s\n' '[{"pin_index": 0, "name": "Café", "geometry": "{\\"type\\":\\"Point\\",\\"coordinates\\":[0,0]}"}]'
      SH
      File.chmod(0o755, fake)
      File.write(File.join(dir, "a.parquet"), "")
      features = L.features(parquet: File.join(dir, "a.parquet"), pin: [-80.0, 35.0], duckdb: fake)

      assert_equal "Café", features.first["name"]
    end
  end

  def test_extension_setting_follows_the_duckdb_version
    Dir.mktmpdir do |dir|
      { "v2.0.1 (Cyanoptera) 8d78114e90" => "SET extension_directories = ['/ext'];",
        "v1.4.4 (Andium) 6ddac802ff" => "SET extension_directory = '/ext';" }.each_with_index do |(version, sql), i|
        fake = File.join(dir, "duckdb#{i}")
        File.write(fake, "#!/bin/sh\ncat > /dev/null\nprintf '%s\\n' '#{version}'\n")
        File.chmod(0o755, fake)

        assert_equal sql, Curtilage::DuckDB.extension_sql("/ext", fake)
      end
    end
  end

  def test_duckdb_agent_mode_is_turned_off
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, <<~SH)
        #!/bin/sh
        cat > /dev/null
        [ "$DUCKDB_AGENT_MODE" = 0 ] || { printf 'agent mode on\n' >&2; exit 1; }
        printf '[]\n'
      SH
      File.chmod(0o755, fake)
      File.write(File.join(dir, "a.parquet"), "")

      assert_equal [], L.features(parquet: File.join(dir, "a.parquet"), pin: [-80.0, 35.0], duckdb: fake)
    end
  end

  def test_missing_duckdb_is_a_curtilage_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.parquet"), "")
      error = assert_raises(Curtilage::Error) do
        L.features(parquet: File.join(dir, "a.parquet"), pin: [-80.0, 35.0], duckdb: File.join(dir, "no-duckdb"))
      end
      assert_match(/DuckDB CLI not found/, error.message)
    end
  end

  def test_every_error_class_is_a_curtilage_error
    [L::Error, Curtilage::Overture::Error, Curtilage::Build::Error, Curtilage::Download::Error,
     Curtilage::Download::Transient, Curtilage::Footprints::Error, Curtilage::ZipRange::Unsupported,
     Curtilage::ZipRange::Corrupt].each { |klass| assert_operator klass, :<, Curtilage::Error }
  end

  def test_missing_parquet_file
    assert_raises(ArgumentError) { L.features(parquet: "/nonexistent.parquet", pin: [-80.0, 35.0]) }
    assert_raises(ArgumentError) { L.features(parquet: [], pin: [-80.0, 35.0]) }
  end

  def test_groups_rows_by_pin
    out = JSON.generate([{ "pin_index" => 1, "id" => 5, "geometry" => '{"type":"Point","coordinates":[0,0]}' }])
    lists = L.group(out, 2)

    assert_empty lists[0]
    assert_equal 5, lists[1].first["id"]
  end

  # One site raising mid-batch gets an error result; the others are fine.
  # Option mistakes still fail the call, before any data is read.
  def test_one_failing_site_doesnt_abort_the_batch
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "duckdb")
      File.write(fake, "#!/bin/sh\ncat > /dev/null\nprintf '[]\\n'\n")
      File.chmod(0o755, fake)
      File.write(File.join(dir, "a.parquet"), "")
      pins = [[-80.0, 35.0], [-80.01, 35.0], [-80.02, 35.0]]
      flaky = lambda do |pin, features, **opts|
        raise ZeroDivisionError, "boom" if pin == pins[1]

        Curtilage::Generator.generate(:building, pin, features, **opts)
      end
      results = with_stub(Curtilage::Generator, :propose, flaky) do
        Curtilage.generate_many(pins, parquet: File.join(dir, "a.parquet"), lookup: { duckdb: fake })
      end

      assert_equal [[], [:error], []], results.map(&:flags)
      assert_includes results[1].problem, "ZeroDivisionError: boom"
      refute_predicate results[1], :ok?
      assert_equal pins[1], results[1].pin
      assert_raises(ArgumentError) do
        Curtilage.generate_many(pins, parquet: File.join(dir, "a.parquet"), lookup: { duckdb: fake }, grow_m: -1)
      end
      assert_raises(ArgumentError) { Curtilage.generate_many(pins, parquet: "x", preset: :nope) }
    end
  end
end
