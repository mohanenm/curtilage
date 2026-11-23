# frozen_string_literal: true

require "json"
require "open3"

module Curtilage
  # The DuckDB CLI, which Lookup, Overture and Build run SQL through.
  module DuckDB
    MAX_ERROR_BYTES = 1_000_000
    # How long a stopped DuckDB gets to exit before it's killed outright.
    GRACE_SECONDS = 2

    module_function

    # [stdout, stderr, status] of the CLI run on sql. A missing binary is a
    # Curtilage::Error saying what to install, not a bare Errno::ENOENT.
    #
    # DuckDB runs in its own process group: past timeout seconds, or once its
    # output passes max_output bytes, the whole group is stopped and this
    # raises, so a stuck or runaway query can't hang the caller or fill its
    # memory. Output is read as it arrives, never more than the cap.
    #
    # DuckDB writes UTF-8; Ruby would otherwise label it with the locale, and
    # under LANG=C a non-ASCII name in the JSON fails to parse.
    # DUCKDB_AGENT_MODE=0: run from an AI coding tool (AI_AGENT, CLAUDECODE
    # and the like), DuckDB 2.0 switches to an "agent mode" that changes its
    # output and prints a notice on stderr. Older versions ignore it.
    def capture(duckdb, sql, *args, timeout: Curtilage.config.duckdb_timeout, max_output: nil)
      Open3.popen3({ "DUCKDB_AGENT_MODE" => "0" }, duckdb, *args, pgroup: true) do |stdin, stdout, stderr, wait|
        feed, out, err = pipe_threads([stdin, stdout, stderr], sql, max_output, wait.pid)
        finished = begin
          wait.join(timeout)
        rescue Exception # rubocop:disable Lint/RescueException
          # Interrupted (Ctrl-C) or killed: DuckDB has its own process group,
          # so the terminal's signal never reached it. Stop it before leaving.
          stop(wait)
          raise
        end
        stop(wait) unless finished
        output = [feed, out, err].map(&:value)[1..]
        raise Error, "DuckDB took over #{timeout} s and was stopped" unless finished
        raise Error, "DuckDB's output passed #{max_output} bytes and it was stopped" if output[0] == :too_large

        [output[0].force_encoding(Encoding::UTF_8), clean(output[1].to_s.force_encoding(Encoding::UTF_8)), wait.value]
      end
    rescue Errno::ENOENT
      raise Error, "DuckDB CLI not found (#{duckdb}). Install DuckDB 1.4 or 2.0 " \
                   "(https://duckdb.org/docs/installation/) or set CURTILAGE_DUCKDB to its path; " \
                   "`curtilage doctor` checks."
    end

    # Threads that write the SQL and read both outputs; their values carry
    # any error, so they don't report it themselves.
    def pipe_threads(pipes, sql, max_output, pid)
      stdin, stdout, stderr = pipes
      [Thread.new { feed(stdin, sql) }, Thread.new { read_capped(stdout, max_output, pid) },
       Thread.new { read_capped(stderr, MAX_ERROR_BYTES, pid) }].each { |t| t.report_on_exception = false }
    end

    def feed(stdin, sql)
      stdin.write(sql)
    rescue Errno::EPIPE, IOError
      nil # DuckDB stopped reading (it exited or was stopped): its status says why
    ensure
      stdin.close unless stdin.closed?
    end

    # All of stream, or :too_large once it passes cap (stopping the process).
    # A stream closed under it (the run was abandoned: interrupted, timed
    # out) ends the read quietly.
    def read_capped(stream, cap, pid)
      data = String.new
      while (chunk = stream.read(65_536))
        data << chunk
        next unless cap && data.bytesize > cap

        signal("TERM", pid)
        return :too_large
      end
      data
    rescue IOError
      data
    end

    # TERM to the whole process group, then KILL if it hasn't gone.
    def stop(wait)
      signal("TERM", wait.pid)
      signal("KILL", wait.pid) unless wait.join(GRACE_SECONDS)
      wait.join
    end

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil # already gone
    end

    # DuckDB's error without the query excerpt it quotes ("LINE 1: ..." and
    # the "^" marker under it): the excerpt can hold the box around a pin,
    # and error messages often travel further than the machine.
    def clean(err)
      err.lines.reject { |l| l.match?(/\A\s*LINE \d+:/) || l.match?(/\A\s*\^+\s*\z/) }.join
    end

    # Where the CLI actually is: duckdb as given if it names a path, else the
    # first match on the PATH, or nil. Whatever this names runs with the
    # user's rights, so doctor shows it.
    def resolve(duckdb)
      return File.expand_path(duckdb) if duckdb.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, duckdb) }
         .find { |file| File.executable?(file) && !File.directory?(file) }
    end

    # The SQL pointing DuckDB at an extension folder. DuckDB 2.0 renamed the
    # setting, and warns about the old name on stdout, inside -json output.
    # Without a duckdb path (SQL built on its own), the 1.x form.
    def extension_sql(dir, duckdb = nil)
      folder = quote(File.expand_path(dir))
      return "SET extension_directories = [#{folder}];" if duckdb && major_version(duckdb) >= 2

      "SET extension_directory = #{folder};"
    end

    # The CLI's version line ("v2.0.1 (Cyanoptera) 8d78114e90"), or nil if
    # it can't be run (the run that needs it reports that); asked once per
    # binary.
    def version(duckdb)
      (@versions ||= {}).fetch(duckdb) do
        out, _, status = capture(duckdb, "", "--version")
        @versions[duckdb] = status.success? ? out.strip : nil
      rescue Error
        nil
      end
    end

    # The CLI's major version (1 if it can't tell).
    def major_version(duckdb)
      version(duckdb).to_s[/\Av?(\d+)\./, 1]&.then { |major| Integer(major) } || 1
    end

    # { "spatial" => "v1.4.4", ... }: the versions of the extensions loaded
    # after setup (SQL that loads them), for doctor and build metadata.
    def extension_versions(duckdb, setup, names)
      list = names.map { |n| quote(n) }.join(", ")
      query = "SELECT extension_name AS name, extension_version AS version FROM duckdb_extensions() " \
              "WHERE loaded AND extension_name IN (#{list});"
      out, err, status = capture(duckdb, "#{setup}\n#{query}", "-json")
      raise Error, "DuckDB extensions (#{names.join(", ")}) could not be loaded: #{err.strip[0, 300]}" \
        unless status.success?

      JSON.parse(out).to_h { |row| [row["name"], row["version"]] }
    end

    # SQL that makes the extensions available: installed if missing, then
    # loaded. Offline, only loaded (from a pre-populated extension folder),
    # with DuckDB's own automatic installs turned off. Signature checks are
    # never relaxed (no allow_unsigned_extensions).
    def load_sql(*names)
      return (["SET autoinstall_known_extensions = false;"] + names.map { |n| "LOAD #{n};" }).join(" ") \
        if Curtilage.offline?

      names.map { |n| "INSTALL #{n}; LOAD #{n};" }.join(" ")
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
