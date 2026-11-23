# frozen_string_literal: true

module Curtilage
  # What `curtilage doctor` checks: everything the gem needs outside Ruby,
  # each with a fix. Returns a report (a Hash) that the command prints as
  # text or JSON.
  module Doctor
    # DuckDB versions the gem is tested with; others may work and get a warning.
    TESTED = [/\Av?1\.4\./, /\Av?2\.0\./].freeze
    INSTALL = {
      "macOS" => "brew install duckdb",
      "Linux" => "download the CLI from https://duckdb.org/docs/installation/ (most distributions don't package it) " \
                 "and set CURTILAGE_DUCKDB to its path",
    }.freeze

    module_function

    # settings: duckdb:, extension_directory: (Curtilage.duckdb_options).
    # verify: a catalogue or cache folder whose built files to check
    # against their recorded SHA256s.
    def report(settings, cache_dir: Curtilage.config.cache_dir, network: false, verify: nil)
      checks = { "duckdb" => duckdb(settings) }
      checks["extensions"] = extensions(settings) if checks["duckdb"]["ok"]
      checks["cache"] = cache(cache_dir) if cache_dir
      checks["built_files"] = built_files(verify) if verify
      checks["network"] = reach if network
      { "ok" => checks.values.all? { |c| c["ok"] }, "offline" => Curtilage.offline?, "checks" => checks }
    end

    def duckdb(settings)
      path = DuckDB.resolve(settings[:duckdb])
      version = DuckDB.version(settings[:duckdb])
      return { "ok" => false, "path" => path, "fix" => INSTALL } unless version

      tested = TESTED.any? { |pattern| version.match?(pattern) }
      { "ok" => true, "path" => path, "version" => version, "tested" => tested,
        "warning" => (tested ? nil : "untested DuckDB version (tested: 1.4 LTS and 2.0); it may still work") }.compact
    end

    def extensions(settings)
      dir = settings[:extension_directory]
      setup = [(DuckDB.extension_sql(dir, settings[:duckdb]) if dir), DuckDB.load_sql("spatial", "httpfs")].compact
      versions = DuckDB.extension_versions(settings[:duckdb], setup.join("\n"), %w[spatial httpfs])
      { "ok" => versions.size == 2, "versions" => versions }
    rescue Error => e
      { "ok" => false, "error" => e.message,
        "fix" => Curtilage.offline? ? "run `curtilage doctor` once online to install them" : "check the network" }
    end

    def cache(dir)
      return { "ok" => true, "path" => dir, "note" => "will be created (0700)" } unless File.exist?(dir)

      problem = AutoData.cache_problem(File.stat(dir), dir)
      problem ? { "ok" => false, "path" => dir, "error" => problem } : { "ok" => true, "path" => dir }
    end

    def built_files(dir)
      catalogue = Catalogue.from_dir(dir)
      problems = catalogue.verify
      { "ok" => problems.empty?, "path" => dir, "regions" => catalogue.regions.size, "problems" => problems,
        "fix" => (problems.empty? ? nil : "rebuild the regions listed") }.compact
    rescue Error => e
      { "ok" => false, "path" => dir, "error" => e.message }
    end

    # Whether the hosts the gem downloads from answer (no locations are sent).
    def reach
      hosts = { Regions::HOST => Regions::INDEX, Overture::STAC_HOST => Overture::CATALOG }
      results = hosts.to_h do |host, path|
        [host, Download.exists?(host, path)]
      rescue Curtilage::Error => e
        [host, e.message]
      end
      { "ok" => results.values.all?(true), "hosts" => results }
    end

    # The report as lines for a terminal.
    def text(report)
      report["checks"].flat_map { |name, check| lines(name, check) } +
        [report["ok"] ? "Ready." : "Not ready: see the fixes above."]
    end

    def lines(name, check)
      mark = check["ok"] ? "ok " : "!! "
      detail = check.except("ok", "fix").map do |k, v|
        "#{k}: #{v.is_a?(Hash) ? v.map { |a, b| "#{a} #{b}" }.join(", ") : v}"
      end
      fixes = Array(check["fix"].is_a?(Hash) ? check["fix"].map { |os, fix| "#{os}: #{fix}" } : check["fix"])
      ["#{mark}#{name}: #{detail.join("; ")}", *fixes.map { |f| "   fix (#{f})" }]
    end
  end
end
