# frozen_string_literal: true

require "open3"

module Curtilage
  # The DuckDB CLI, which Lookup, Overture and Build run SQL through.
  module DuckDB
    module_function

    # [stdout, stderr, status] of the CLI run on sql. A missing binary is a
    # Curtilage::Error saying what to install, not a bare Errno::ENOENT.
    def capture(duckdb, sql, *)
      Open3.capture3(duckdb, *, stdin_data: sql)
    rescue Errno::ENOENT
      raise Error, "DuckDB CLI not found (#{duckdb}). Install DuckDB 1.4 (https://duckdb.org/docs/installation/) " \
                   "or set CURTILAGE_DUCKDB to its path; `curtilage doctor` checks."
    end

    # A SQL string literal.
    def quote(text)
      "'#{text.to_s.gsub("'", "''")}'"
    end
  end
end
