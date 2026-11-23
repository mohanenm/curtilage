# frozen_string_literal: true

require "digest"
require "json"

module Curtilage
  # The built regions available to look features up in, from the
  # <region>.json files Build writes next to each Parquet file. Picks the
  # file(s) covering a pin, so callers don't track which state is which.
  class Catalogue
    # rings: the region's outline when the build recorded it, else nil (older
    # builds), in which case its bounding box stands in.
    Region = Struct.new(:name, :parquet, :bbox, :rings, :metadata, keyword_init: true) do
      def covers?(pin, margin)
        Geometry.box_points(pin, margin).any? { |point| holds?(point) }
      end

      def holds?(point) = Geometry.in_rings?(point, bbox, rings)
    end

    attr_reader :regions

    # dir: a folder of <region>.json and <region>.parquet files. base_url:
    # where the Parquet files are served from instead (s3://bucket/path,
    # https://...), when the metadata is local but the data isn't.
    def self.from_dir(dir, base_url: nil)
      new(Dir.glob(File.join(dir, "*.json")).filter_map { |file| region(file, dir, base_url) })
    end

    # A Region from one <region>.json, or nil if it isn't one. A file that
    # claims to be one but can't be read is an error, not a silent gap.
    def self.region(file, dir, base_url)
      meta = JSON.parse(File.read(file, encoding: "utf-8"))
      return nil unless meta.is_a?(Hash) && meta["format"] == 1 && meta["parquet"] && meta["bbox"]&.size == 4

      parquet = base_url ? "#{base_url.chomp("/")}/#{meta["parquet"]}" : File.join(dir, meta["parquet"])
      rings = meta["outline"]&.map { |ring| ring.map { |lng, lat| [Float(lng), Float(lat)] } }
      Region.new(name: meta["region"], parquet: parquet, bbox: meta["bbox"].map { |v| Float(v) }, rings: rings,
                 metadata: meta)
    rescue JSON::ParserError, ArgumentError, TypeError, NoMethodError => e
      raise Error, "unreadable catalogue file #{file}: #{e.message[0, 200]}"
    end

    def initialize(regions)
      @regions = regions
    end

    # Parquet files whose extent covers the pin (more than one near a border).
    def files_for(pin, margin: Lookup::DEFAULT_RADIUS_DEG)
      @regions.select { |r| r.covers?(pin, margin) }.map(&:parquet)
    end

    # :full when every point of the pin's box lies in a built region, :partial
    # when some do (the rest is in a region that isn't built), :none when
    # none do. Regions built before outlines were recorded count by their
    # bounding box, which can't tell :partial from :full.
    def coverage(pin, margin: Lookup::DEFAULT_RADIUS_DEG)
      points = Geometry.box_points(pin, margin)
      held = points.count { |point| @regions.any? { |r| r.holds?(point) } }
      return :none if held.zero?

      held == points.size ? :full : :partial
    end

    # Problems with the local Parquet files against what their metadata
    # recorded (size and SHA256): missing, truncated or altered files.
    def verify
      @regions.filter_map do |r|
        next if r.parquet.match?(Lookup::REMOTE) || !r.metadata["parquet_sha256"]
        next "#{r.parquet}: missing" unless File.file?(r.parquet)
        next "#{r.parquet}: #{File.size(r.parquet)} bytes, expected #{r.metadata["parquet_bytes"]}" \
          if File.size(r.parquet) != r.metadata["parquet_bytes"]

        next if Digest::SHA256.file(r.parquet).hexdigest == r.metadata["parquet_sha256"]

        "#{r.parquet}: SHA256 differs from its metadata"
      end
    end

    def attribution(files)
      @regions.select { |r| files.include?(r.parquet) }.flat_map { |r| Array(r.metadata["attribution"]) }.uniq
    end
  end
end
