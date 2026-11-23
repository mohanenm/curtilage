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
    # DUCKDB_AGENT_MODE=0: run from an AI coding tool (AI_AGENT, CLAUDECODE
    # and the like), DuckDB 2.0 switches to an "agent mode" that changes its
    # output and prints a notice on stderr. Older versions ignore it.
    def capture(duckdb, sql, *)
      out, err, status = Open3.capture3({ "DUCKDB_AGENT_MODE" => "0" }, duckdb, *, stdin_data: sql)
      [out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8), status]
    rescue Errno::ENOENT
      raise Error, "DuckDB CLI not found (#{duckdb}). Install DuckDB 1.4 or 2.0 " \
                   "(https://duckdb.org/docs/installation/) or set CURTILAGE_DUCKDB to its path; " \
                   "`curtilage doctor` checks."
    end

    # The SQL pointing DuckDB at an extension folder. DuckDB 2.0 renamed the
    # setting, and warns about the old name on stdout, inside -json output.
    # Without a duckdb path (SQL built on its own), the 1.x form.
    def extension_sql(dir, duckdb = nil)
      folder = quote(File.expand_path(dir))
      return "SET extension_directories = [#{folder}];" if duckdb && major_version(duckdb) >= 2

      "SET extension_directory = #{folder};"
    end

    # The CLI's major version (1 if it can't tell), asked once per binary.
    def major_version(duckdb)
      (@major_versions ||= {})[duckdb] ||= begin
        out, _, status = capture(duckdb, "", "--version")
        status.success? && out[/\Av?(\d+)\./, 1] ? Integer(Regexp.last_match(1)) : 1
      end
    end

    # A SQL string literal. Line breaks and NUL bytes are refused: no real
    # path or URL has them, and the CLI reads a line starting with "." as one
    # of its own commands.
    def quote(text)
      text = text.to_s
      raise ArgumentError, "text for DuckDB can't contain line breaks or NUL bytes: #{text.inspect}" \
        if text.match?(/[\r\n\0]/)

      "'#{text.gsub("'", "''")}'"
    end

    # A DuckDB memory size ("400MB", "1.5 GiB"), checked rather than only
    # quoted, so a mistake fails clearly instead of inside DuckDB.
    MEMORY = /\A\d+(\.\d+)?\s?(KB|MB|GB|TB|KiB|MiB|GiB|TiB)\z/i

    def memory_limit(value)
      raise ArgumentError, "memory_limit looks like \"400MB\" or \"2GB\": #{value.inspect}" \
        unless value.to_s.match?(MEMORY)

      "SET memory_limit = #{quote(value)};"
    end
  end
end
