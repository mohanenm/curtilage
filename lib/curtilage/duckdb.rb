# frozen_string_literal: true

require "open3"

module Curtilage
  # The DuckDB CLI, which Lookup, Overture and Build run SQL through.
  module DuckDB
    module_function

    # [stdout, stderr, status] of the CLI run on sql. A missing binary is a
    # Curtilage::Error saying what to install, not a bare Errno::ENOENT.
    # DuckDB writes UTF-8; Ruby would otherwise label it with the locale, and
    # under LANG=C a non-ASCII name in the JSON fails to parse.
    def capture(duckdb, sql, *)
      out, err, status = Open3.capture3(duckdb, *, stdin_data: sql)
      [out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8), status]
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
