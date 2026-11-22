# frozen_string_literal: true

require "fileutils"
require "zlib"

module Curtilage
  # Extracts chosen members of a remote zip with HTTP range requests, so only
  # the layers the build uses are downloaded (about 70% of a Geofabrik
  # shapefile zip). Members are inflated as they stream in and checked
  # against the zip's CRC-32s. Raises Unsupported for anything unusual
  # (no range support, zip64, encryption, other compression), so the caller
  # can fall back to a full download.
  module ZipRange
    class Unsupported < Curtilage::Error; end
    class Corrupt < Curtilage::Error; end

    Entry = Struct.new(:name, :compression, :crc, :compressed_size, :uncompressed_size, :offset, :data_end,
                       keyword_init: true)

    EOCD_SIGNATURE = [0x06054b50].pack("V")
    CENTRAL_SIGNATURE = 0x02014b50
    LOCAL_SIGNATURE = 0x04034b50
    TAIL_BYTES = 65_557 # end-of-central-directory record plus the longest comment
    MAX_ENTRIES = 1_000

    module_function

    # Extracts the members whose names match any of patterns (File.fnmatch)
    # into dir. Returns the extracted file paths.
    def extract(host, path, patterns, dir, max_bytes:)
      entries = entries(host, path)
      chosen = entries.select { |e| patterns.any? { |p| File.fnmatch(p, File.basename(e.name)) } }
      raise Unsupported, "no members match #{patterns.join(", ")}" if chosen.empty?
      raise Unsupported, "members over #{max_bytes} bytes" if chosen.sum(&:compressed_size) > max_bytes

      FileUtils.mkdir_p(dir)
      # Each run (adjacent members) streams on its own connection, in parallel.
      # All finish before any error is raised: the caller may delete dir.
      threads = runs(chosen).map do |run|
        Thread.new do
          Thread.current.report_on_exception = false
          fetch_run(host, path, run, dir)
        end
      end
      Curtilage.join_all(threads).flatten
    end

    # The zip's central directory, each entry knowing where its bytes end.
    def entries(host, path)
      length = content_length(host, path)
      tail = range(host, path, [length - TAIL_BYTES, 0].max, length - 1)
      eocd = tail.rindex(EOCD_SIGNATURE) or raise Unsupported, "no end-of-central-directory record"
      count, cd_size, cd_offset = tail.byteslice(eocd + 10, 10).unpack("vVV")
      if count == 0xFFFF || cd_offset == 0xFFFFFFFF || count > MAX_ENTRIES
        raise Unsupported,
              "zip64 or too many entries"
      end

      list = parse_central(range(host, path, cd_offset, cd_offset + cd_size - 1), count)
      ends = list.map(&:offset).sort + [cd_offset]
      list.each { |e| e.data_end = ends[ends.index(e.offset) + 1] }
    end

    def parse_central(bytes, count)
      pos = 0
      Array.new(count) do
        raise Corrupt, "bad central directory" unless bytes.byteslice(pos, 4).unpack1("V") == CENTRAL_SIGNATURE

        flags, method, _time, _date, crc, csize, size, name_len, extra_len, comment_len =
          bytes.byteslice(pos + 8, 26).unpack("vvvvVVVvvv")
        offset = bytes.byteslice(pos + 42, 4).unpack1("V")
        raise Unsupported, "encrypted member" if flags.anybits?(1)
        raise Unsupported, "compression method #{method}" unless [0, 8].include?(method)

        name = bytes.byteslice(pos + 46, name_len)
        pos += 46 + name_len + extra_len + comment_len
        Entry.new(name: name, compression: method, crc: crc, compressed_size: csize, uncompressed_size: size,
                  offset: offset)
      end
    end

    # Groups entries whose bytes are adjacent into one request each.
    def runs(entries)
      entries.sort_by(&:offset).slice_when { |a, b| a.data_end != b.offset }.to_a
    end

    # A retry starts the run again from its first byte, with a fresh reader.
    def fetch_run(host, path, run, dir)
      Download.with_retries("downloading #{File.basename(run.first.name)} and the files after it") do
        reader = RunReader.new(run, dir)
        Download.stream_range(host, path, run.first.offset, run.last.data_end - 1) { |chunk| reader << chunk }
        reader.finish
      end
    end

    def content_length(host, path)
      Download.with_retries("checking https://#{host}#{path}") { head_length(host, path) }
    end

    def head_length(host, path)
      Download.start(host) do |http|
        res = http.head(path)
        raise Download::Transient, "HTTP #{res.code}" if res.is_a?(Net::HTTPServerError)
        raise Download::Error, "HTTP #{res.code} for https://#{host}#{path}" unless res.is_a?(Net::HTTPSuccess)
        raise Unsupported, "no range support" unless res["Accept-Ranges"].to_s.include?("bytes")

        Integer(res["Content-Length"])
      end
    end

    def range(host, path, first, last)
      Download.with_retries("reading the zip directory of https://#{host}#{path}") do
        Download.start(host) do |http|
          res = http.get(path, "Range" => "bytes=#{first}-#{last}")
          raise Download::Transient, "HTTP #{res.code}" if res.is_a?(Net::HTTPServerError)
          raise Unsupported, "server ignored the range request" unless res.code == "206"

          res.body
        end
      end
    end

    # Walks a run of members as bytes arrive: local header, name, data
    # (inflated to a file), then on to the next member's offset.
    class RunReader
      def initialize(run, dir)
        @members = run.dup
        @dir = dir
        @pos = run.first.offset
        @buffer = +""
        @paths = []
        start_member
      end

      def <<(chunk)
        @buffer << chunk
        step while @member && !@buffer.empty? && progress?
      rescue Zlib::Error => e
        raise ZipRange::Corrupt, "#{@member&.name} doesn't inflate: #{e.message}"
      end

      def finish
        raise Corrupt, "download ended inside #{@member.name}" if @member

        @paths
      end

      private

      def start_member
        @member = @members.shift
        @phase = :skip
      end

      def progress?
        return @buffer.bytesize >= 30 if @phase == :header
        return @buffer.bytesize >= @name_bytes if @phase == :name

        true
      end

      def step
        send(:"step_#{@phase}")
      end

      def step_skip
        take([@member.offset - @pos, @buffer.bytesize].min)
        @phase = :header if @pos == @member.offset
      end

      def step_header
        header = take(30)
        raise ZipRange::Corrupt, "bad local header" unless header.unpack1("V") == LOCAL_SIGNATURE

        name_len, extra_len = header.byteslice(26, 4).unpack("vv")
        @name_bytes = name_len + extra_len
        @phase = :name
      end

      def step_name
        take(@name_bytes)
        open_output
        @phase = :data
      end

      def step_data
        bytes = take([@remaining, @buffer.bytesize].min)
        @remaining -= bytes.bytesize
        write(bytes)
        finish_member if @remaining.zero?
      end

      def open_output
        name = File.basename(@member.name)
        raise ZipRange::Corrupt, "bad member name" unless name.match?(/\A[\w.-]+\z/)

        @path = File.join(@dir, name)
        @file = File.open(@path, "wb")
        @inflate = @member.compression == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS) : nil
        @crc = 0
        @written = 0
        @remaining = @member.compressed_size
      end

      # Raw member bytes: inflated first when the member is compressed.
      def write(bytes)
        write_inflated(@inflate ? @inflate.inflate(bytes) : bytes)
      end

      def write_inflated(data)
        @written += data.bytesize
        raise ZipRange::Corrupt, "#{@member.name} inflates past its size" if @written > @member.uncompressed_size

        @crc = Zlib.crc32(data, @crc)
        @file.write(data)
      end

      def finish_member
        if @inflate
          write_inflated(@inflate.finish)
          @inflate.close
        end
        @file.close
        check_member
        @paths << @path
        start_member
      end

      def check_member
        return if @crc == @member.crc && @written == @member.uncompressed_size

        File.delete(@path)
        raise ZipRange::Corrupt, "#{@member.name} failed its CRC check"
      end

      def take(count)
        bytes = @buffer.byteslice(0, count)
        @buffer = @buffer.byteslice(count..) || +""
        @pos += bytes.bytesize
        bytes
      end
    end
  end
end
