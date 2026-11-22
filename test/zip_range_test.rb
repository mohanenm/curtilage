# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "zlib"

# Builds a small zip in memory (stored and deflated members, one with a data
# descriptor) and feeds it to the range reader in awkward chunk sizes.
class ZipRangeTest < Minitest::Test
  Z = Curtilage::ZipRange

  MEMBERS = {
    "a/gis_osm_roads_free_1.shp" => "roads " * 500,
    "a/gis_osm_water_free_1.shp" => "water " * 300,
    "a/gis_osm_roads_free_1.dbf" => "attributes " * 200,
    "a/README" => "hello",
  }.freeze

  def zip_bytes(corrupt: false)
    out = +""
    central = +""
    MEMBERS.each_with_index do |(name, data), i|
      method = i.even? ? 8 : 0
      body = if method == 8
               Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).deflate(data,
                                                                                      Zlib::FINISH)
             else
               data
             end
      crc = Zlib.crc32(data)
      crc ^= 1 if corrupt && i.zero?
      flags = i == 2 ? 8 : 0
      offset = out.bytesize
      out << [0x04034b50, 20, flags, method, 0, 0, flags == 8 ? 0 : crc, flags == 8 ? 0 : body.bytesize,
              flags == 8 ? 0 : data.bytesize, name.bytesize, 3].pack("VvvvvvVVVvv") << name << "xyz" << body
      out << [0x08074b50, crc, body.bytesize, data.bytesize].pack("VVVV") if flags == 8
      central << [0x02014b50, 20, 20, flags, method, 0, 0, crc, body.bytesize, data.bytesize, name.bytesize,
                  0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
    end
    cd_offset = out.bytesize
    out << central << [0x06054b50, 0, 0, MEMBERS.size, MEMBERS.size, central.bytesize, cd_offset, 0].pack("VvvvvVVv")
  end

  def extract(bytes, chunk)
    eocd = bytes.rindex([0x06054b50].pack("V"))
    count, size, offset = bytes.byteslice(eocd + 10, 10).unpack("vVV")
    entries = Z.parse_central(bytes.byteslice(offset, size), count)
    ends = entries.map(&:offset).sort + [offset]
    entries.each { |e| e.data_end = ends[ends.index(e.offset) + 1] }
    chosen = entries.select { |e| File.fnmatch("gis_osm_roads_free_*", File.basename(e.name)) }
    Dir.mktmpdir do |dir|
      Z.runs(chosen).each do |run|
        reader = Z::RunReader.new(run, dir)
        span = bytes.byteslice(run.first.offset, run.last.data_end - run.first.offset)
        (0...span.bytesize).step(chunk) { |i| reader << span.byteslice(i, chunk) }
        reader.finish
      end
      yield dir, Z.runs(chosen)
    end
  end

  def test_extracts_only_the_chosen_members_whatever_the_chunk_size
    [1, 7, 4096].each do |chunk|
      extract(zip_bytes, chunk) do |dir, runs|
        assert_equal 2, runs.size
        assert_equal MEMBERS["a/gis_osm_roads_free_1.shp"], File.read(File.join(dir, "gis_osm_roads_free_1.shp"))
        assert_equal MEMBERS["a/gis_osm_roads_free_1.dbf"], File.read(File.join(dir, "gis_osm_roads_free_1.dbf"))
        refute File.exist?(File.join(dir, "gis_osm_water_free_1.shp"))
      end
    end
  end

  def test_data_that_wont_inflate_is_corrupt
    entry = Z::Entry.new(name: "x.shp", compression: 8, crc: 0, compressed_size: 8, uncompressed_size: 8, offset: 0,
                         data_end: 38)
    Dir.mktmpdir do |dir|
      reader = Z::RunReader.new([entry], dir)
      header = [0x04034b50, 20, 0, 8, 0, 0, 0, 8, 8, 5, 0].pack("VvvvvvVVVvv")

      assert_raises(Z::Corrupt) { reader << "#{header}x.shp#{"\xFF".b * 8}" }
    end
  end

  def test_crc_mismatch_is_caught
    assert_raises(Z::Corrupt) { extract(zip_bytes(corrupt: true), 64) { nil } }
  end
end
