# frozen_string_literal: true

require "json"

module Curtilage
  # Writing a big run as it goes (the command line's generate): NDJSON and
  # CSV are streamed chunk by chunk, so memory stays flat, into OUT.part
  # (renamed to OUT at the end, so readers never see half a file), which
  # --resume picks up after a crash or Ctrl-C. GeoJSON and KML are single
  # documents, so they're written whole at the end.
  class Batch
    CHUNK = 500
    STREAMED = %i[ndjson csv].freeze

    attr_reader :done

    # out: a path, or nil for io. resume: carry on from OUT.part.
    def initialize(format:, out: nil, store: true, resume: false, output: $stdout)
      @format = format.to_sym
      @out = out
      @store = store
      @io = output
      @done = Set.new
      @buffer = [[], []]
      raise ArgumentError, "--resume needs --out FILE.ndjson or FILE.csv" if resume && !(out && streamed?)

      if out && streamed?
        open_part(resume)
      elsif streamed? && @format == :csv
        @io.write(Formats.csv_text([Formats::CSV_COLUMNS]))
      end
    end

    def streamed? = STREAMED.include?(@format)

    # The .part file next to out; its fixed name is what lets a later run
    # resume it.
    def part = File.join(File.dirname(File.expand_path(@out)), ".#{File.basename(@out)}.part")

    def add(results, ids)
      return @buffer.zip([results, ids]).each { |list, more| list.concat(more) } unless streamed?

      text = Formats.write(results, @format, ids: ids, store: @store)
      text = text.lines.drop(1).join if @format == :csv
      (@file || @io).write(text)
      (@file || @io).flush
      @done.merge(ids)
    end

    def finish
      if @file
        @file.close
        File.rename(part, @out)
      elsif !streamed?
        text = Formats.write(@buffer[0], @format, ids: @buffer[1], store: @store)
        return yield(text) if @out

        @io.write(text.end_with?("\n") ? text : "#{text}\n")
      end
    end

    private

    def open_part(resume)
      if resume && File.file?(part)
        keep_whole_lines
        @done = Set.new(written_ids)
        @file = File.open(part, "a")
      else
        @file = File.open(part, "w")
        @file.write(Formats.csv_text([Formats::CSV_COLUMNS])) if @format == :csv
      end
    end

    # A crash can cut the last line short: drop it, so its site runs again.
    def keep_whole_lines
      text = File.binread(part)
      return if text.empty? || text.end_with?("\n")

      File.truncate(part, (text.rindex("\n") || -1) + 1)
    end

    def written_ids
      text = File.read(part, encoding: "utf-8")
      if @format == :csv
        Formats.parse_csv(text, max_rows: Float::INFINITY).drop(1).map(&:first)
      else
        text.each_line.map { |l| JSON.parse(l).dig("properties", "id").to_s }
      end
    rescue JSON::ParserError, ArgumentError => e
      raise ArgumentError, "can't resume from #{part}: #{e.message[0, 200]}"
    end

    # Sites done per second and the time left, on a terminal.
    class Progress
      def initialize(total, output: $stderr, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @total = total
        @io = output
        @clock = clock
        @start = clock.call
        @done = 0
      end

      def step(count)
        @done += count
        elapsed = @clock.call - @start
        rate = elapsed.positive? ? @done.to_f / elapsed : 0
        left = rate.positive? ? ((@total - @done) / rate).round : 0
        @io.print "\r#{@done}/#{@total} sites (#{@done * 100 / [@total, 1].max}%), " \
                  "#{rate.round(1)}/s, about #{format("%<m>d:%<s>02d", m: left / 60, s: left % 60)} left  "
      end

      def finish = @io.puts
    end
  end
end
