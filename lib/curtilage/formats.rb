# frozen_string_literal: true

require "cgi/escape"
require "json"
require "strscan"

module Curtilage
  # Pins in from CSV, GeoJSON or NDJSON; results out as GeoJSON, NDJSON, CSV
  # or KML. Used by
  # the command line, and handy from Ruby:
  #
  #   sites = Curtilage::Formats.read_pins("sites.csv")
  #   results = Curtilage.generate_many(sites.map { |s| s[:pin] })
  #   File.write("premises.kml", Curtilage::Formats.write(results, :kml, ids: sites.map { |s| s[:id] }))
  #
  # Plain Ruby (no csv gem): CSV is read and written per RFC 4180 (quoted
  # fields, doubled quotes, commas and newlines inside quotes).
  module Formats
    INPUTS = %i[csv geojson ndjson].freeze
    OUTPUTS = %i[geojson ndjson csv kml].freeze
    LNG_COLUMNS = %w[lng lon long longitude].freeze
    LAT_COLUMNS = %w[lat latitude].freeze
    ID_COLUMNS = %w[id site_id name].freeze
    # Inputs are untrusted: cap what a file can ask for.
    MAX_PINS = 100_000
    MAX_BYTES = 50 * 1024 * 1024
    MAX_FIELD_CHARS = 10_000
    MAX_COLUMNS = 1_000
    # Rings read back from result files: generated ones have at most 200.
    MAX_RESULT_VERTICES = 1_000

    CSV_COLUMNS = %w[id lng lat ok problem method flags errors building building_area_m2 parking_area_m2
                     parking_spaces_estimate frontage_m premises_area_m2 premises_wkt store_wkt attribution
                     gem_version data_source data_release features_sha256 confidence approach_wkt pickup_wkt
                     staging_wkt pin_quality candidates].freeze

    module_function

    # The format a path's extension names (.csv, .geojson/.json,
    # .ndjson/.jsonl, .kml), or nil.
    def format_of(path)
      case File.extname(path.to_s).downcase
      when ".csv" then :csv
      when ".geojson", ".json" then :geojson
      when ".ndjson", ".jsonl" then :ndjson
      when ".kml" then :kml
      end
    end

    # [{ id:, pin: [lng, lat] }, ...] from a CSV (a header row with lng/lon/
    # longitude and lat/latitude columns, and optionally id/site_id/name),
    # GeoJSON (Point features; id from the feature's id or properties id or
    # name) or NDJSON (one site per line, see ndjson_pins). Rows without an
    # id are numbered from 1.
    def read_pins(path, format: nil)
      format ||= format_of(path) or
        raise ArgumentError, "can't tell the format of #{path}: use .csv, .geojson or .ndjson"
      raise ArgumentError, "#{path} is over #{MAX_BYTES / 1024 / 1024} MB" if File.size(path) > MAX_BYTES

      text = File.read(path, encoding: "bom|utf-8")
      parse_pins(text, format.to_sym)
    end

    def parse_pins(text, format)
      text = checked_text(text)
      sites = case format
              when :csv then csv_pins(text)
              when :geojson then geojson_pins(text)
              when :ndjson then ndjson_pins(text)
              else raise ArgumentError, "unknown input format #{format.inspect} (have: #{INPUTS.join(", ")})"
              end
      raise ArgumentError, "more than #{MAX_PINS} pins" if sites.size > MAX_PINS

      sites.each.with_index(1) do |site, i|
        site[:id] ||= i.to_s
        raise ArgumentError, "#{site[:id]}: a pin is LNG,LAT (longitude first)" unless pin?(site[:pin])
      end
    end

    # The text as valid UTF-8 without a byte-order mark, refused up front if
    # it's too big, isn't UTF-8 or holds NUL bytes (a binary file, usually).
    def checked_text(text)
      raise ArgumentError, "the input is over #{MAX_BYTES / 1024 / 1024} MB" if text.bytesize > MAX_BYTES

      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      raise ArgumentError, "the input isn't valid UTF-8" unless text.valid_encoding?
      raise ArgumentError, "the input contains a NUL byte: is it a text file?" if text.include?("\0")

      text.delete_prefix("\uFEFF")
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
      raise ArgumentError, "more than #{MAX_PINS} pins" if features.size > MAX_PINS

      features.each_with_index.map { |f, i| geojson_pin(f, "feature #{i + 1}") }
    rescue JSON::ParserError => e
      raise ArgumentError, "not valid GeoJSON: #{e.message[0, 200]}"
    end

    # One site per line: a GeoJSON Point Feature, {"id", "pin": [lng, lat]}
    # or {"id", "lng", "lat"} (any of the CSV column names). Blank lines are
    # skipped.
    def ndjson_pins(text)
      lines = text.each_line.with_index(1).reject { |line, _| line.strip.empty? }
      raise ArgumentError, "more than #{MAX_PINS} pins" if lines.size > MAX_PINS

      lines.map { |line, n| ndjson_pin(line, "line #{n}") }
    end

    def ndjson_pin(line, where)
      row = JSON.parse(line, max_nesting: 20)
      raise ArgumentError, "#{where} isn't a JSON object" unless row.is_a?(Hash)
      return geojson_pin(row, where) if row["type"] == "Feature"

      coords = row["pin"] || [row.values_at(*LNG_COLUMNS).compact.first, row.values_at(*LAT_COLUMNS).compact.first]
      unless coords.is_a?(Array) && coords.size == 2 && coords.none?(&:nil?)
        raise ArgumentError, "#{where} needs pin: [lng, lat] or lng and lat"
      end

      id = row["id"] || row["site_id"] || row["name"]
      { id: present(id), pin: coords.map { |v| number(v, where) } }
    rescue JSON::ParserError => e
      raise ArgumentError, "#{where} isn't valid JSON: #{e.message[0, 200]}"
    end

    # Premises read back from a GeoJSON or NDJSON file of results (this
    # gem's output, edited or not, or any polygons with an id): { id =>
    # { ring:, store_ring:, properties: } }. A feature's id is its
    # properties.id or its id; properties.role picks premises (the default)
    # or store, and other zones are skipped. ring is nil where the file has
    # no premises. Rings aren't validated here (Corrections and Diff do).
    def read_results(path, format: nil)
      format ||= format_of(path)
      raise ArgumentError, "results are .geojson or .ndjson: #{path}" unless %i[geojson ndjson].include?(format)
      raise ArgumentError, "#{path} is over #{MAX_BYTES / 1024 / 1024} MB" if File.size(path) > MAX_BYTES

      parse_results(File.read(path, encoding: "bom|utf-8"), format)
    rescue SystemCallError => e
      raise ArgumentError, "can't read #{path}: #{e.message}"
    end

    def parse_results(text, format)
      text = checked_text(text)
      features = if format == :ndjson
                   text.each_line.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l, max_nesting: 30) }
                 else
                   doc = JSON.parse(text, max_nesting: 30)
                   doc.is_a?(Hash) && doc["type"] == "FeatureCollection" ? doc["features"] : [doc]
                 end
      raise ArgumentError, "expected GeoJSON Features" unless features.is_a?(Array)
      raise ArgumentError, "more than #{MAX_PINS * 10} features" if features.size > MAX_PINS * 10

      features.each_with_index.with_object({}) { |(f, i), out| add_result(out, f, "feature #{i + 1}") }
    rescue JSON::ParserError => e
      raise ArgumentError, "not valid GeoJSON: #{e.message[0, 200]}"
    end

    def add_result(out, feature, where)
      raise ArgumentError, "#{where} isn't a Feature" unless feature.is_a?(Hash) && feature["type"] == "Feature"

      props = feature["properties"].is_a?(Hash) ? feature["properties"] : {}
      id = present(props["id"] || feature["id"]) or raise ArgumentError, "#{where} has no id"
      entry = out[id] ||= { ring: nil, store_ring: nil, properties: {} }
      case props.fetch("role", "premises")
      when "premises"
        entry.merge!(ring: polygon_ring(feature["geometry"], where), properties: props)
        entry[:store_ring] ||= polygon_ring(props["store"], where) if props["store"]
      when "store" then entry[:store_ring] = polygon_ring(feature["geometry"], where)
      end
    end

    def polygon_ring(geometry, where)
      return nil if geometry.nil?
      unless geometry.is_a?(Hash) && geometry["type"] == "Polygon" && geometry["coordinates"].is_a?(Array)
        raise ArgumentError, "#{where} isn't a Polygon"
      end

      ring = geometry["coordinates"][0]
      unless ring.is_a?(Array) && ring.size <= MAX_RESULT_VERTICES
        raise ArgumentError, "#{where} has more than #{MAX_RESULT_VERTICES} vertices"
      end

      ring
    end

    PLACE_COLUMNS = %w[id lng lat name brand category place_confidence place_sources place_licences].freeze

    # Places (Curtilage.places) as pins to generate from, in :csv, :ndjson
    # or :geojson: id, lng and lat, which read_pins reads back, plus the
    # place's name, brand, category, Overture confidence, sources and
    # licences.
    def write_places(places, format)
      rows = places.map do |p|
        [p[:id], *p[:pin], p[:name], p[:brand], p[:category], p[:confidence], p[:sources].join(";"),
         p[:licences].join(";")]
      end
      case format.to_sym
      when :csv then csv_text([PLACE_COLUMNS] + rows)
      when :ndjson then rows.map { |row| "#{JSON.generate(PLACE_COLUMNS.zip(row).to_h)}\n" }.join
      when :geojson then JSON.pretty_generate(places_geojson(places, rows))
      else raise ArgumentError, "unknown places format #{format.inspect} (have: csv, ndjson, geojson)"
      end
    end

    def places_geojson(places, rows)
      features = places.zip(rows).map do |place, row|
        { type: "Feature", id: place[:id], geometry: { type: "Point", coordinates: place[:pin] },
          properties: PLACE_COLUMNS.zip(row).to_h.except("lng", "lat") }
      end
      { type: "FeatureCollection", features: features }
    end

    # The results as text in format (:geojson, :ndjson, :csv or :kml). ids:
    # one per result (default 1, 2, ...). store: include the store zones.
    def write(results, format, ids: nil, store: true)
      ids ||= (1..results.size).map(&:to_s)
      case format.to_sym
      when :geojson then JSON.pretty_generate(geojson(results, ids, store))
      when :ndjson then ndjson(results, ids, store)
      when :csv then csv(results, ids)
      when :kml then kml(results, ids, store)
      else raise ArgumentError, "unknown output format #{format.inspect} (have: #{OUTPUTS.join(", ")})"
      end
    end

    # One FeatureCollection: each result's premises (and store zone, and
    # any zones asked for), with its id in properties.
    def geojson(results, ids, store)
      features = results.zip(ids).flat_map do |result, id|
        list = result.geojson_features(properties: { id: id })
        store ? list : list.reject { |f| f[:properties][:role] == "store" }
      end
      { type: "FeatureCollection", features: features }
    end

    # One GeoJSON Feature per line (docs/schema/site-v1.json): the premises,
    # with the store zone's geometry in properties.store.
    def ndjson(results, ids, store)
      results.zip(ids).map do |result, id|
        premises, store_zone = result.geojson_features(properties: { id: id })
        premises[:properties][:store] = store_zone[:geometry] if store
        premises[:properties][:approach] = Result.polygon(result.approach_ring) if result.approach_ring
        premises[:properties][:pickup] = Result.polygon(result.pickup_ring) if result.pickup_ring
        premises[:properties][:staging] = Result.point(result.staging_point) if result.staging_point
        premises[:properties][:candidates] = result.candidate_summaries if result.candidates
        "#{JSON.generate(premises)}\n"
      end.join
    end

    def csv(results, ids)
      csv_text([CSV_COLUMNS] + results.zip(ids).map { |result, id| csv_row(result, id) })
    end

    # Every cell guarded (csv_field), CRLF line ends.
    def csv_text(rows) = rows.map { |row| row.map { |v| csv_field(v) }.join(",") }.join("\r\n") << "\r\n"

    def csv_row(result, id)
      d = result.details || {}
      [id, *result.pin, result.ok?, result.problem, result.method_name, result.flags.join(";"),
       result.validation.errors.join(";"), result.building, d.dig(:building, :area_m2), d[:parking_area_m2],
       d[:parking_spaces_estimate],
       d[:frontage_m], result.validation.metrics[:area_m2]&.round, result.to_wkt, result.store_wkt,
       credits(result).join("; "), *provenance_columns(result), *later_columns(result)]
    end

    # Columns added after the first release, in order.
    def later_columns(result)
      [result.confidence, result.approach_wkt, result.pickup_wkt, result.staging_wkt,
       result.pin_quality&.dig(:quality), result.candidates&.size]
    end

    # gem_version, data_source, data_release, features_sha256 (the full
    # record, options included, is in the GeoJSON).
    def provenance_columns(result)
      prov = result.provenance || {}
      [prov[:gem_version], prov.dig(:data, :source), release(prov[:data]), prov[:features_sha256]]
    end

    # The Overture release, or the Geofabrik extract date(s).
    def release(data)
      return nil unless data

      data[:release] || data[:regions]&.flat_map { |r| r[:extract_dates] || [] }&.uniq&.join(";")
    end

    def kml(results, ids, store)
      marks = results.zip(ids).flat_map { |result, id| kml_marks(result, id, store) }
      <<~KML
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
        <name>curtilage</name>
        <description>#{xml("Map data: #{results.flat_map { |r| credits(r) }.uniq.join("; ")}")}</description>
        <Style id="premises"><LineStyle><color>ff4a9a1a</color><width>2</width></LineStyle><PolyStyle><color>334a9a1a</color></PolyStyle></Style>
        <Style id="store"><LineStyle><color>ff111111</color><width>2</width></LineStyle><PolyStyle><fill>0</fill></PolyStyle></Style>
        <Style id="approach"><LineStyle><color>ffc06515</color><width>1</width></LineStyle><PolyStyle><fill>0</fill></PolyStyle></Style>
        <Style id="candidate"><LineStyle><color>ff2090ff</color><width>1</width></LineStyle><PolyStyle><fill>0</fill></PolyStyle></Style>
        <Style id="pickup"><LineStyle><color>ff0080ff</color><width>2</width></LineStyle><PolyStyle><color>440080ff</color></PolyStyle></Style>
        #{marks.join("\n")}
        </Document></kml>
      KML
    end

    # Every placemark for one result: its polygons, then its points.
    def kml_marks(result, id, store)
      polygons = [placemark("#{id} premises", result.ring, kml_description(result), "premises"),
                  (placemark("#{id} store", result.store_ring, nil, "store") if store),
                  placemark("#{id} approach", result.approach_ring, nil, "approach"),
                  placemark("#{id} pickup (estimated)", result.pickup_ring, nil, "pickup")]
      entrances = result.entrances.map do |e|
        point_mark("#{id} entrance from #{e[:street] || e[:street_class]}", e[:point])
      end
      points = [point_mark("#{id} staging (estimated)", result.staging_point)] + entrances
      (polygons + candidate_marks(result, id) + points).compact
    end

    def candidate_marks(result, id)
      result.candidate_summaries.map do |c|
        placemark("#{id} candidate #{c[:rank]}", c[:geometry][:coordinates][0],
                  "confidence #{c[:confidence]}; flags: #{c[:flags].join(", ")}", "candidate")
      end
    end

    def placemark(name, ring, description, style)
      return nil unless ring

      coords = ring.map { |lng, lat| "#{lng},#{lat},0" }.join(" ")
      desc = description ? "<description>#{xml(description)}</description>" : ""
      "<Placemark><name>#{xml(name)}</name>#{desc}<styleUrl>##{style}</styleUrl>" \
        "<Polygon><outerBoundaryIs><LinearRing><coordinates>#{coords}</coordinates></LinearRing></outerBoundaryIs>" \
        "</Polygon></Placemark>"
    end

    def point_mark(name, lnglat)
      lnglat && "<Placemark><name>#{xml(name)}</name><Point><coordinates>#{lnglat.join(",")},0</coordinates></Point>" \
                "</Placemark>"
    end

    def kml_description(result)
      parts = [result.problem || "ok", "confidence #{result.confidence}"]
      parts << "flags: #{result.flags.join(", ")}" if result.flags.any?
      parts << credits(result).join("; ")
      gem, source, release = provenance_columns(result)
      parts << "curtilage #{gem}; data: #{[source, release].compact.join(" ")}" if gem
      parts.join("\n")
    end

    def xml(text) = CGI.escapeHTML(text.to_s)

    # What to credit wherever this result is shown.
    def credits(result) = result.attribution || Result::OSM_ATTRIBUTION

    # What a spreadsheet may run as a formula: =, +, -, @, | (DDE) or %, or
    # their full-width forms, after any leading whitespace; or a leading tab
    # or carriage return.
    FORMULA = /\A(?:[\s\u3000]*[=+\-@|%\uFF1D\uFF0B\uFF0D\uFF20\uFF5C\uFF05]|[\t\r])/
    PLAIN_NUMBER = /\A[+-]?\d+(\.\d+)?\z/

    # Every CSV cell goes through here: one a spreadsheet would run as a
    # formula gets a leading quote, unless it's a plain number.
    def csv_field(value)
      text = value.to_s
      text = "'#{text}" if text.match?(FORMULA) && !text.match?(PLAIN_NUMBER)
      text.match?(/[",\r\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
    end

    # RFC 4180: rows of fields; quoted fields may hold commas, quotes ("")
    # and newlines. Blank lines are skipped. Rows, columns and field length
    # are capped as it reads, so an oversized file fails early.
    def parse_csv(text, max_rows: MAX_PINS + 1)
      scanner = StringScanner.new(text)
      rows = []
      until scanner.eos?
        row = [csv_cell(scanner)]
        row << csv_cell(scanner) while scanner.scan(",") && row.size <= MAX_COLUMNS
        raise ArgumentError, "line #{rows.size + 1} has more than #{MAX_COLUMNS} columns" if row.size > MAX_COLUMNS

        scanner.scan(/\r\n|\n|\r/)
        rows << row unless row == [""]
        raise ArgumentError, "more than #{max_rows - 1} rows" if rows.size > max_rows
      end
      rows
    end

    def csv_cell(scanner)
      value = if scanner.scan('"')
                quoted = scanner.scan(/(?:[^"]|"")*/).gsub('""', '"')
                scanner.scan('"') or raise ArgumentError, "a quoted CSV field is never closed"
                quoted
              else
                scanner.scan(/[^,\r\n]*/)
              end
      raise ArgumentError, "a CSV field is over #{MAX_FIELD_CHARS} characters" if value.size > MAX_FIELD_CHARS

      value
    end

    def present(value)
      text = value.to_s.strip
      raise ArgumentError, "an id is over #{MAX_FIELD_CHARS} characters" if text.size > MAX_FIELD_CHARS

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
      Validation.coordinate(value, [value])
    rescue ArgumentError
      raise ArgumentError, "#{where}: #{value.inspect} isn't a number"
    end

    # A pin from "LNG,LAT" text (the command line's --pin).
    def pin_from_text(text, where = "--pin #{text}")
      parts = text.to_s.split(",")
      raise ArgumentError, "#{where}: a pin is LNG,LAT" unless parts.size == 2

      parts.map { |v| number(v, where) }
    end
  end
end
