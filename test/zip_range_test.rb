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

  def entry(name, compressed, uncompressed)
    Z::Entry.new(name: name, compression: 8, crc: 0, compressed_size: compressed, uncompressed_size: uncompressed,
                 offset: 0)
  end

  def test_decompression_bombs_and_odd_names_are_refused
    ok = [entry("a/gis_osm_roads_free_1.shp", 1_000_000, 8_000_000)]

    assert_equal ok, Z.choose(ok, ["gis_osm_roads_free_*"], 10**9)
    assert_raises(Z::Corrupt) { Z.choose([entry("gis_osm_roads_free_1.shp", 1_000, 50_000_000)], ["gis_*"], 10**9) }
    huge = Array.new(3) { |i| entry("gis_osm_roads_free_#{i}.shp", 5 * (10**9), 9 * (10**9)) }
    assert_raises(Z::Corrupt) { Z.choose(huge, ["gis_*"], 10**11) }
    assert_raises(Z::Corrupt) { Z.choose([entry("a/gis_osm roads.shp", 10, 10)], ["gis_*"], 10**9) }
    assert_raises(Z::Unsupported) { Z.choose(ok, ["nothing_*"], 10**9) }
  end

  def test_a_zip_on_disk_gets_the_same_checks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "region.shp.zip")
      File.binwrite(path, zip_bytes)

      assert_equal 2, Z.check_local(path, ["gis_osm_roads_free_*"], max_bytes: 10**9).size
      assert_raises(Z::Unsupported) { Z.check_local(path, ["gis_osm_roads_free_*"], max_bytes: 10) }
    end
  end

  def test_a_zip_on_disk_extracts_without_unzip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "region.shp.zip")
      File.binwrite(path, zip_bytes)
      out = File.join(dir, "layers")
      paths = Z.extract_local(path, ["gis_osm_roads_free_*"], out, max_bytes: 10**9)

      assert_equal 2, paths.size
      assert_equal MEMBERS["a/gis_osm_roads_free_1.shp"], File.read(File.join(out, "gis_osm_roads_free_1.shp"))
      refute_path_exists File.join(out, "gis_osm_water_free_1.shp")
      File.binwrite(path, zip_bytes(corrupt: true))
      assert_raises(Z::Corrupt) { Z.extract_local(path, ["gis_osm_roads_free_*"], File.join(dir, "bad"), max_bytes: 10**9) }
    end
  end
end
