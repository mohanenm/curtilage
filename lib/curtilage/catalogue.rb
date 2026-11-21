# frozen_string_literal: true

require "json"

module Curtilage
  # The built regions available to look features up in, from the
  # <region>.json files Build writes next to each Parquet file. Picks the
  # file(s) covering a pin, so callers don't track which state is which.
  class Catalogue
    Region = Struct.new(:name, :parquet, :bbox, :metadata, keyword_init: true) do
      def covers?(pin, margin)
        lng, lat = pin
        lng.between?(bbox[0] - margin, bbox[2] + margin) && lat.between?(bbox[1] - margin, bbox[3] + margin)
      end
    end

    attr_reader :regions

    # dir: a folder of <region>.json and <region>.parquet files. base_url:
    # where the Parquet files are served from instead (s3://bucket/path,
    # https://...), when the metadata is local but the data isn't.
    def self.from_dir(dir, base_url: nil)
      regions = Dir.glob(File.join(dir, "*.json")).filter_map do |file|
        meta = JSON.parse(File.read(file))
        next unless meta["format"] == 1 && meta["parquet"] && meta["bbox"]&.size == 4

        parquet = base_url ? "#{base_url.chomp("/")}/#{meta["parquet"]}" : File.join(dir, meta["parquet"])
        Region.new(name: meta["region"], parquet: parquet, bbox: meta["bbox"].map { |v| Float(v) }, metadata: meta)
      end
      new(regions)
    end

    def initialize(regions)
      @regions = regions
    end

    # Parquet files whose extent covers the pin (more than one near a border).
    def files_for(pin, margin: Lookup::DEFAULT_RADIUS_DEG)
      @regions.select { |r| r.covers?(pin, margin) }.map(&:parquet)
    end

    def attribution(files)
      @regions.select { |r| files.include?(r.parquet) }.flat_map { |r| Array(r.metadata["attribution"]) }.uniq
    end
  end
end
