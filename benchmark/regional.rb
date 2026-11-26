# frozen_string_literal: true

# The regional check's official layers (benchmark/regional/README.md),
# fetched whole, page by page, into data/regional/<region>/ (gitignored,
# never committed). Each feature is kept as its class and geometry only:
# parcel layers carry owner names, which never reach the cache.
module CurtilageBenchmark
  DC_GIS = "https://maps2.dcgis.dc.gov/dcgis/rest/services/DCGIS_DATA"
  # DC Planimetrics 2023 roads, FEATURECODE => class: medians, islands and
  # intersections are part of the roadway.
  DC_ROAD_CLASSES = { 1050 => "road", 1055 => "road", 1056 => "road", 1057 => "road", 1058 => "road",
                      1060 => "alley", 1065 => "driveway", 1070 => "parking", 1090 => "road", 1091 => "road",
                      1092 => "road", 1093 => "road" }.freeze
  REGIONAL_LAYERS = {
    "dc" => [
      { name: "roads", url: "#{DC_GIS}/Planimetrics_2023/MapServer/10", field: "FEATURECODE",
        classes: DC_ROAD_CLASSES, page: 500 },
      { name: "sidewalks", url: "#{DC_GIS}/Planimetrics_2023/MapServer/11", class: "sidewalk", page: 250 },
      { name: "buildings", url: "#{DC_GIS}/Planimetrics_2023/MapServer/1", class: "building" },
      { name: "parcels", url: "#{DC_GIS}/Property_and_Land/MapServer/40", class: "parcel" },
    ],
  }.freeze
  REGIONAL_CLASSES = %w[building parking driveway road sidewalk alley parcel].freeze
  REGIONAL_PAGE = 1000
  REGIONAL_MAX_VERTICES = 20_000

  module_function

  def regional_dir(region) = File.join(ROOT, "data", "regional", region)

  # Fetches every layer of the region not fetched yet, recording each one's
  # source, date, feature count and SHA256 in manifest.json.
  def fetch_regional(region, dir: regional_dir(region))
    layers = REGIONAL_LAYERS.fetch(region) { raise ArgumentError, "no regional layers for #{region.inspect}" }
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "manifest.json")
    manifest = File.exist?(path) ? JSON.parse(File.read(path)) : {}
    layers.reject { |l| manifest.key?(l[:name]) }.each do |layer|
      file = File.join(dir, "#{layer[:name]}.ndjson")
      count = File.open("#{file}.part", "w") { |out| fetch_layer(layer, out) }
      File.rename("#{file}.part", file)
      manifest[layer[:name]] = { "source" => layer[:url], "fetched_at" => Time.now.utc.iso8601, "features" => count,
                                 "sha256" => Digest::SHA256.file(file).hexdigest }
      File.write(path, "#{JSON.pretty_generate(manifest)}\n")
    end
    manifest
  end

  # Writes the layer's features to out, one JSON object per line; returns
  # how many were kept.
  def fetch_layer(layer, out)
    offset = kept = 0
    loop do
      doc = regional_page(layer, offset)
      features = Array(doc["features"])
      features.each do |f|
        row = regional_row(layer, f) or next
        out.puts(JSON.generate(row))
        kept += 1
      end
      offset += features.size
      break if features.empty? || !doc["exceededTransferLimit"]
    end
    kept
  end

  def regional_page(layer, offset)
    query = { where: "1=1", outFields: ["OBJECTID", layer[:field]].compact.join(","), returnGeometry: true,
              outSR: 4326, geometryPrecision: 7, orderByFields: "OBJECTID", resultOffset: offset,
              resultRecordCount: layer.fetch(:page, REGIONAL_PAGE), f: "geojson" }
    doc = arcgis_get(URI("#{layer[:url]}/query?#{URI.encode_www_form(query)}"))
    raise "#{URI(layer[:url]).host}: #{doc.dig("error", "message")}" if doc["error"]

    doc
  end

  # { "class" =>, "geometry" => } for a polygon of a known class, else nil.
  # Map data is untrusted: oversized or malformed outlines are dropped.
  def regional_row(layer, feature)
    geometry = feature["geometry"]
    klass = layer[:class] || layer[:classes][feature.dig("properties", layer[:field]).to_i]
    return nil unless klass && geometry.is_a?(Hash) && %w[Polygon MultiPolygon].include?(geometry["type"])

    vertices = geometry["coordinates"].flatten.size / 2
    vertices <= REGIONAL_MAX_VERTICES ? { "class" => klass, "geometry" => geometry } : nil
  end
end
