# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Every value that reaches SQL from configuration, the environment or a
# path stays inside a quoted literal, or is refused.
class SqlSafetyTest < Minitest::Test
  HOSTILE = "x'; COPY (SELECT 1) TO '/tmp/pwn.csv'; --"
  PIN = [-80.0, 35.0].freeze

  # The SQL with every quoted literal blanked: what DuckDB would run as code.
  def code(sql)
    sql.gsub(/'(?:[^']|'')*'/, "''")
  end

  def assert_contained(sql)
    refute_match(/COPY|pwn/, code(sql), sql)
  end

  def test_lookup_paths_urls_and_extension_folder_stay_quoted
    sql = Curtilage::Lookup.sql([HOSTILE, "s3://bucket/#{HOSTILE}"], [PIN], HOSTILE, 0.004)

    assert_contained(sql)
    assert_includes sql, "x''; COPY"
  end

  def test_overture_files_and_extension_folder_stay_quoted
    box = Curtilage::Overture.box(PIN, 0.004)

    assert_contained(Curtilage::Overture.grouped_scan("building", [HOSTILE], [0], [box]))
    assert_contained(Curtilage::Overture.setup({ extension_directory: HOSTILE }, remote: true))
  end

  def test_build_settings_stay_quoted_or_are_refused
    settings = { memory_limit: "400MB", threads: 1, temp_directory: HOSTILE, extension_directory: HOSTILE }

    assert_contained(Curtilage::Build.setup(settings))
    assert_contained(Curtilage::Build.ml_view([HOSTILE], [-81, 34, -79, 36]))
    ["400MB'; COPY (SELECT 1) TO '/tmp/pwn.csv'; --", "lots", "-1GB"].each do |bad|
      assert_raises(ArgumentError) { Curtilage::Build.setup(settings.merge(memory_limit: bad)) }
    end
    ["2; COPY", 0, 65, "x"].each do |bad|
      assert_raises(ArgumentError) { Curtilage::Build.setup(settings.merge(threads: bad)) }
    end
  end

  def test_line_breaks_and_nul_bytes_are_refused
    ["a\n.shell touch /tmp/pwn", "a\r.system id", "a\0b"].each do |bad|
      assert_raises(ArgumentError) { Curtilage::DuckDB.quote(bad) }
      assert_raises(ArgumentError) { Curtilage::Lookup.sql([bad], [PIN], nil, 0.004) }
    end
  end

  def test_a_catalogue_bucket_url_stays_quoted
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "east.json"),
                 JSON.generate(format: 1, region: "test/east", parquet: "east.parquet", bbox: [-85, 34, -75, 37]))
      files = Curtilage::Catalogue.from_dir(dir, base_url: "s3://bucket/#{HOSTILE}").files_for(PIN)

      assert_contained(Curtilage::Lookup.sql(files, [PIN], nil, 0.004))
    end
  end

  def test_memory_sizes
    %w[400MB 2GB 1.5GiB 512KiB].push("1 TB").each do |ok|
      assert_includes Curtilage::DuckDB.memory_limit(ok), "SET memory_limit"
    end
  end
end
