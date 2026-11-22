# frozen_string_literal: true

require "json"
require "strscan"

module Curtilage
  # Pins in from CSV or GeoJSON; results out as GeoJSON, CSV or KML. Used by
  # the command line, and handy from Ruby:
  #
  #   sites = Curtilage::Formats.read_pins("sites.csv")
  #   results = Curtilage.generate_many(sites.map { |s| s[:pin] })
  #   File.write("premises.kml", Curtilage::Formats.write(results, :kml, ids: sites.map { |s| s[:id] }))
  #
  # Plain Ruby (no csv gem): CSV is read and written per RFC 4180 (quoted
  # fields, doubled quotes, commas and newlines inside quotes).
  module Formats
    INPUTS = %i[csv geojson].freeze
    OUTPUTS = %i[geojson csv kml].freeze
    LNG_COLUMNS = %w[lng lon long longitude].freeze
    LAT_COLUMNS = %w[lat latitude].freeze
    ID_COLUMNS = %w[id site_id name].freeze
    # Inputs are untrusted: cap what a file can ask for.
    MAX_PINS = 100_000
    MAX_BYTES = 50 * 1024 * 1024

    CSV_COLUMNS = %w[id lng lat ok problem method flags errors building building_area_m2 parking_area_m2
                     parking_spaces_estimate frontage_m premises_area_m2 premises_wkt store_wkt].freeze

    module_function

    # The format a path's extension names (.csv, .geojson/.json, .kml), or nil.
    def format_of(path)
      case File.extname(path.to_s).downcase
      when ".csv" then :csv
      when ".geojson", ".json" then :geojson
      when ".kml" then :kml
      end
    end

    # [{ id:, pin: [lng, lat] }, ...] from a CSV (a header row with lng/lon/
    # longitude and lat/latitude columns, and optionally id/site_id/name) or
    # GeoJSON (Point features; id from the feature's id or properties id or
    # name). Rows without an id are numbered from 1.
    def read_pins(path, format: nil)
      format ||= format_of(path) or raise ArgumentError, "can't tell the format of #{path}: use .csv or .geojson"
      raise ArgumentError, "#{path} is over #{MAX_BYTES / 1024 / 1024} MB" if File.size(path) > MAX_BYTES

      text = File.read(path, encoding: "bom|utf-8")
      parse_pins(text, format.to_sym)
    end

    def parse_pins(text, format)
      sites = case format
              when :csv then csv_pins(text)
              when :geojson then geojson_pins(text)
              else raise ArgumentError, "unknown input format #{format.inspect} (have: #{INPUTS.join(", ")})"
              end
      raise ArgumentError, "more than #{MAX_PINS} pins" if sites.size > MAX_PINS

      sites.each.with_index(1) { |site, i| site[:id] ||= i.to_s }
    end

    def csv_pins(text)
      header, *rows = parse_csv(text)
      raise ArgumentError, "the CSV is empty" unless header

      names = header.map { |h| h.to_s.strip.downcase }
      lng, lat, id = [LNG_COLUMNS, LAT_COLUMNS, ID_COLUMNS].map { |list| names.index { |n| list.include?(n) } }
      raise ArgumentError, "the CSV needs lng and lat columns (have: #{names.join(", ")})" unless lng && lat

      rows.each_with_index.map do |row, i|
        { id: id && present(row[id]), pin: [number(row[lng], "line #{i + 2}"), number(row[lat], "line #{i + 2}")] }
      end
    end

    def geojson_pins(text)
      doc = JSON.parse(text, max_nesting: 20)
      features = doc.is_a?(Hash) && doc["type"] == "FeatureCollection" ? doc["features"] : [doc]
      raise ArgumentError, "expected GeoJSON Point features" unless features.is_a?(Array)

      features.each_with_index.map { |f, i| geojson_pin(f, "feature #{i + 1}") }
    rescue JSON::ParserError => e
      raise ArgumentError, "not valid GeoJSON: #{e.message[0, 200]}"
    end

    # The results as text in format (:geojson, :csv or :kml). ids: one per
    # result (default 1, 2, ...). store: include the store zones.
    def write(results, format, ids: nil, store: true)
      ids ||= (1..results.size).map(&:to_s)
      case format.to_sym
      when :geojson then JSON.pretty_generate(geojson(results, ids, store))
      when :csv then csv(results, ids)
      when :kml then kml(results, ids, store)
      else raise ArgumentError, "unknown output format #{format.inspect} (have: #{OUTPUTS.join(", ")})"
      end
    end

    # One FeatureCollection: each result's premises (and store zone), with
    # its id in properties.
    def geojson(results, ids, store)
      features = results.zip(ids).flat_map do |result, id|
        list = result.geojson_features(properties: { id: id })
        store ? list : list.first(1)
      end
      { type: "FeatureCollection", features: features }
    end

    def csv(results, ids)
      rows = results.zip(ids).map { |result, id| csv_row(result, id) }
      ([CSV_COLUMNS] + rows).map { |row| row.map { |v| csv_field(v) }.join(",") }.join("\r\n") << "\r\n"
    end

    def csv_row(result, id)
      d = result.details || {}
      [id, *result.pin, result.ok?, result.problem, result.method_name, result.flags.join(";"),
       result.validation.errors.join(";"), result.building, d.dig(:building, :area_m2), d[:parking_area_m2],
       d[:parking_spaces_estimate],
       d[:frontage_m], result.validation.metrics[:area_m2]&.round, result.to_wkt, result.store_wkt]
    end

    def kml(results, ids, store)
      marks = results.zip(ids).flat_map do |result, id|
        [placemark("#{id} premises", result.ring, kml_description(result), "premises"),
         (placemark("#{id} store", result.store_ring, nil, "store") if store)].compact
      end
      <<~KML
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
        <name>curtilage</name>
        <Style id="premises"><LineStyle><color>ff4a9a1a</color><width>2</width></LineStyle><PolyStyle><color>334a9a1a</color></PolyStyle></Style>
        <Style id="store"><LineStyle><color>ff111111</color><width>2</width></LineStyle><PolyStyle><fill>0</fill></PolyStyle></Style>
        #{marks.join("\n")}
        </Document></kml>
      KML
    end

    def placemark(name, ring, description, style)
      return nil unless ring

      coords = ring.map { |lng, lat| "#{lng},#{lat},0" }.join(" ")
      desc = description ? "<description>#{xml(description)}</description>" : ""
      "<Placemark><name>#{xml(name)}</name>#{desc}<styleUrl>##{style}</styleUrl>" \
        "<Polygon><outerBoundaryIs><LinearRing><coordinates>#{coords}</coordinates></LinearRing></outerBoundaryIs>" \
        "</Polygon></Placemark>"
    end

    def kml_description(result)
      parts = [result.problem || "ok"]
      parts << "flags: #{result.flags.join(", ")}" if result.flags.any?
      parts << (result.attribution || Result::OSM_ATTRIBUTION).join("; ")
      parts.join("\n")
    end

    def xml(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    # A field that a spreadsheet would run as a formula (=, +, -, @) gets a
    # leading quote, unless it's a number.
    def csv_field(value)
      text = value.to_s
      text = "'#{text}" if text.match?(/\A[=+\-@\t\r]/) && !text.match?(/\A[+-]?\d+(\.\d+)?\z/)
      text.match?(/[",\r\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
    end

    # RFC 4180: rows of fields; quoted fields may hold commas, quotes ("")
    # and newlines. Blank lines are skipped.
    def parse_csv(text)
      scanner = StringScanner.new(text)
      rows = []
      until scanner.eos?
        row = [csv_cell(scanner)]
        row << csv_cell(scanner) while scanner.scan(",")
        scanner.scan(/\r\n|\n|\r/)
        rows << row unless row == [""]
      end
      rows
    end

    def csv_cell(scanner)
      return scanner.scan(/[^,\r\n]*/) unless scanner.scan('"')

      value = scanner.scan(/(?:[^"]|"")*/).gsub('""', '"')
      scanner.scan('"') or raise ArgumentError, "a quoted CSV field is never closed"
      value
    end

    def present(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    # [lng, lat] within range (a pin given lat first usually isn't).
    def pin?(pin)
      pin.size == 2 && pin[0].abs <= 180 && pin[1].abs <= 90
    end

    def geojson_pin(feature, where)
      geometry = feature.is_a?(Hash) && feature["geometry"]
      coords = geometry.is_a?(Hash) && geometry["type"] == "Point" && geometry["coordinates"]
      raise ArgumentError, "#{where} isn't a Point" unless coords.is_a?(Array) && coords.size >= 2

      props = feature["properties"].is_a?(Hash) ? feature["properties"] : {}
      { id: present(feature["id"] || props["id"] || props["name"]), pin: coords.first(2).map { |v| number(v, where) } }
    end

    def number(value, where)
      Float(value.to_s.strip)
    rescue ArgumentError
      raise ArgumentError, "#{where}: #{value.inspect} isn't a number"
    end
  end
end
