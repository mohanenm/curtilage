# frozen_string_literal: true

require "json"
require "curtilage"
require_relative "runner"

# Fails if any benchmark site lies within 1 km of a site in the given
# private lists (CSV, GeoJSON points, or JSON with "pin" entries). The lists
# are only read locally, so a private site never ends up in the public
# benchmark by accident.
#
#   ruby -Ilib benchmark/check_sites.rb private/sites.csv private/more.json
module CurtilageBenchmark
  MIN_DISTANCE_M = 1_000

  module_function

  def private_pins(path)
    format = Curtilage::Formats.format_of(path)
    return Curtilage::Formats.read_pins(path).map { |s| s[:pin] } if format == :csv

    doc = JSON.parse(File.read(path, encoding: "utf-8"))
    list = doc.is_a?(Hash) ? doc["sites"] || doc["features"] || [] : Array(doc)
    list.filter_map do |item|
      next unless item.is_a?(Hash)

      pin = item["pin"] || item.dig("geometry", "coordinates")
      pin.first(2).map { |v| Float(v) } if pin.is_a?(Array) && pin.size >= 2
    end
  end

  # [[site id, metres to the nearest private pin], ...] for sites too close.
  def too_close(sites, pins, min: MIN_DISTANCE_M)
    sites.filter_map do |site|
      nearest = pins.map { |p| G.distance([0, 0], G.project([p], site["pin"]).first) }.min
      [site["id"], nearest.round] if nearest && nearest < min
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: ruby -Ilib benchmark/check_sites.rb PRIVATE_LIST..." if ARGV.empty?
  pins = ARGV.flat_map { |path| CurtilageBenchmark.private_pins(path) }
  close = CurtilageBenchmark.too_close(CurtilageBenchmark.sites, pins)
  close.each { |id, metres| warn "#{id}: #{metres} m from a private site" }
  abort "#{close.size} benchmark site(s) too close to private sites" unless close.empty?
  puts "#{CurtilageBenchmark.sites.size} benchmark sites checked against #{pins.size} private pins: all over 1 km away"
end
