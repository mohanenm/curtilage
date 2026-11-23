# frozen_string_literal: true

# Settings shared by every call, so callers don't pass them each time.
# Defaults come from the environment:
#
#   CURTILAGE_DUCKDB      path to the DuckDB CLI (default: "duckdb" on PATH)
#   CURTILAGE_EXTENSIONS  DuckDB extension folder (default: DuckDB's own)
#   CURTILAGE_CACHE_DIR   where on-demand builds are kept (default: a
#                         temporary folder, deleted after each run)
#   CURTILAGE_SOURCE      auto (default), geofabrik or overture
#   CURTILAGE_DUCKDB_TIMEOUT  seconds a lookup or Overture query may take
#                         before DuckDB is stopped (default 600)
#   CURTILAGE_OFFLINE     1: never touch the network (no downloads, no
#                         extension installs, no Overture or bucket reads)
#
#   Curtilage.configure do |c|
#     c.cache_dir = "/var/cache/curtilage"
#     c.source = :overture
#   end
module Curtilage
  Config = Struct.new(:duckdb, :extension_directory, :cache_dir, :source, :duckdb_timeout, :offline,
                      keyword_init: true)

  def self.config
    @config ||= Config.new(
      duckdb: ENV.fetch("CURTILAGE_DUCKDB", "duckdb"),
      extension_directory: ENV.fetch("CURTILAGE_EXTENSIONS", nil),
      cache_dir: ENV.fetch("CURTILAGE_CACHE_DIR", nil),
      source: ENV.fetch("CURTILAGE_SOURCE", "auto").to_sym,
      duckdb_timeout: seconds(ENV.fetch("CURTILAGE_DUCKDB_TIMEOUT", "600")),
      offline: %w[1 true yes].include?(ENV.fetch("CURTILAGE_OFFLINE", "").downcase)
    )
  end

  def self.offline? = config.offline == true

  # Raises if offline mode forbids what's about to happen.
  def self.online!(what)
    raise Error, "offline mode (CURTILAGE_OFFLINE) forbids #{what}" if offline?
  end

  def self.seconds(value)
    number = Float(value, exception: false)
    raise ArgumentError, "CURTILAGE_DUCKDB_TIMEOUT must be a number of seconds: #{value.inspect}" \
      unless number&.positive? && number.finite?

    number
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
