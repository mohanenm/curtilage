# frozen_string_literal: true

# Settings shared by every call, so callers don't pass them each time.
# Defaults come from the environment:
#
#   CURTILAGE_DUCKDB      path to the DuckDB CLI (default: "duckdb" on PATH)
#   CURTILAGE_EXTENSIONS  DuckDB extension folder (default: DuckDB's own)
#   CURTILAGE_CACHE_DIR   where on-demand builds are kept (default: a
#                         temporary folder, deleted after each run)
#   CURTILAGE_SOURCE      geofabrik (default) or overture
#
#   Curtilage.configure do |c|
#     c.cache_dir = "/var/cache/curtilage"
#     c.source = :overture
#   end
module Curtilage
  Config = Struct.new(:duckdb, :extension_directory, :cache_dir, :source, keyword_init: true)

  def self.config
    @config ||= Config.new(
      duckdb: ENV.fetch("CURTILAGE_DUCKDB", "duckdb"),
      extension_directory: ENV.fetch("CURTILAGE_EXTENSIONS", nil),
      cache_dir: ENV.fetch("CURTILAGE_CACHE_DIR", nil),
      source: ENV.fetch("CURTILAGE_SOURCE", "geofabrik").to_sym
    )
  end

  def self.configure
    yield config
    config
  end

  # Back to the environment defaults (mostly for tests).
  def self.reset_config!
    @config = nil
  end

  # The DuckDB settings for Lookup, Build and Overture: explicit options win
  # over the configuration.
  def self.duckdb_options(options = {})
    defaults = { duckdb: config.duckdb, extension_directory: config.extension_directory }.compact
    defaults.merge(options.compact)
  end
end
