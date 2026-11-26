# frozen_string_literal: true

# The regional check's official layers (benchmark/regional/README.md),
# fetched whole (a jurisdiction, a box or a list of towns), page by page, into data/regional/<region>/ (gitignored,
# never committed). Each feature is kept as its class and geometry only:
# parcel layers carry owner names, which never reach the cache.
module CurtilageBenchmark
  DC_GIS = "https://maps2.dcgis.dc.gov/dcgis/rest/services/DCGIS_DATA"
  # DC Planimetrics 2023 roads, FEATURECODE => class: medians, islands and
  # intersections are part of the roadway.
  DC_ROAD_CLASSES = { 1050 => "road", 1055 => "road", 1056 => "road", 1057 => "road", 1058 => "road",
                      1060 => "alley", 1065 => "driveway", 1070 => "parking", 1090 => "road", 1091 => "road",
                      1092 => "road", 1093 => "road" }.freeze
  # DC Planimetrics 2023 buildings, FEATURECODE => class: memorials,
  # bleachers and fountains are other structures.
  DC_BUILDING_CLASSES = { 2000 => "building", 2010 => "structure", 2020 => "structure", 2030 => "parking_garage",
                          2040 => "structure", 2050 => "canopy" }.freeze
  DRCOG = "https://gis.drcog.org/server/rest/services/RDC"
  DENVER_BOX = [-105.11, 39.61, -104.60, 39.92].freeze # City and County of Denver, with some of its neighbours
  # DRCOG 2024 roofprints, Bldg_Type => class (the rest are buildings).
  DENVER_BUILDING_CLASSES = Hash.new("building").merge("Garage/Shed" => "shed", "Parking Structure" => "parking_garage",
                                                       "Tank" => "structure", "Foundation/Ruin" => "structure").freeze
  CT_GIS = "https://services3.arcgis.com/3FL1kr7L4LvwA2Kb/arcgis/rest/services"
  CT_TOWNS = %w[Hartford Waterbury Norwalk Danbury Milford Manchester].freeze # urban to suburban
  # Connecticut 2023 impervious, CateTitle => class; sports grounds, pools
  # and railways aren't used.
  CT_CLASSES = { "building" => "building", "driveway" => "driveway", "parking" => "parking", "road" => "road",
                 "bridge" => "road", "sidewalk" => "sidewalk", "pavement" => "paved" }.freeze
  REGIONAL_LAYERS = {
    "dc" => [
      { name: "roads", url: "#{DC_GIS}/Planimetrics_2023/MapServer/10", field: "FEATURECODE",
        classes: DC_ROAD_CLASSES, page: 500 },
      { name: "sidewalks", url: "#{DC_GIS}/Planimetrics_2023/MapServer/11", class: "sidewalk", page: 250 },
      { name: "buildings", url: "#{DC_GIS}/Planimetrics_2023/MapServer/1", field: "FEATURECODE",
        classes: DC_BUILDING_CLASSES },
      { name: "parcels", url: "#{DC_GIS}/Property_and_Land/MapServer/40", class: "parcel" },
    ],
    "denver" => [
      { name: "parking", url: "#{DRCOG}/PLANIMETRICS_2024_PAVED_PARKING_TOTAL/MapServer/0", class: "parking" },
      { name: "driveways", url: "#{DRCOG}/PLANIMETRICS_2024_POLYGON_DRIVEWAYS_TOTAL/MapServer/0", class: "driveway" },
      { name: "roads", url: "#{DRCOG}/PLANIMETRICS_2024_EDGE_PAVEMENT_POLYGON_TOTAL/MapServer/0", class: "road",
        page: 250 },
      { name: "sidewalks", url: "#{DRCOG}/PLANIMETRICS_2024_POLYGON_SIDEWALKS_TOTAL/MapServer/0", class: "sidewalk",
        page: 500 },
      { name: "buildings", url: "#{DRCOG}/PLANIMETRICS_2024_BUILDING_ROOFPRINTS_TOTAL/MapServer/0",
        field: "Bldg_Type", classes: DENVER_BUILDING_CLASSES },
      { name: "parcels", url: "https://services1.arcgis.com/zdB7qR0BtYrg0Xpl/arcgis/rest/services/ODC_PROP_PARCELS_A/FeatureServer/245",
        class: "parcel" },
    ].map { |l| l.merge(box: DENVER_BOX) },
    "ct" => [
      { name: "impervious", url: "#{CT_GIS}/Impervious_Surface_Land_Connecticut_2023/FeatureServer/1",
        field: "CateTitle", classes: CT_CLASSES, where: "TOWN_NAME IN (#{CT_TOWNS.map { |t| "'#{t}'" }.join(", ")})" },
      { name: "parcels", url: "#{CT_GIS}/Connecticut_State_Parcel_Layer_2023/FeatureServer/0", class: "parcel",
        where: "Town_Name IN (#{CT_TOWNS.map { |t| "'#{t}'" }.join(", ")})" },
    ],
  }.freeze
  REGIONAL_PAGE = 1000
  REGIONAL_MIN_PAGE = 50
  REGIONAL_TRIES = 4
  REGIONAL_RETRY_S = 10
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
      kept, dropped = File.open("#{file}.part", "w") { |out| fetch_layer(layer, out) }
      File.rename("#{file}.part", file)
      manifest[layer[:name]] = { "source" => layer[:url], "fetched_at" => Time.now.utc.iso8601, "features" => kept,
                                 "dropped" => dropped, "sha256" => Digest::SHA256.file(file).hexdigest }
      File.write(path, "#{JSON.pretty_generate(manifest)}\n")
    end
    manifest
  end

  # Writes the layer's features to out, one JSON object per line; returns
  # [kept, dropped]. Pages are in OBJECTID order: a page that doesn't move
  # past the last one (a server ignoring the offset) stops the fetch.
  def fetch_layer(layer, out)
    offset = kept = 0
    last = -1
    page = layer.fetch(:page, REGIONAL_PAGE)
    loop do
      doc, page = regional_page(layer, offset, page)
      features = Array(doc["features"])
      last = moved_on(layer, offset, features, last)
      rows = features.filter_map { |f| regional_row(layer, f) }
      rows.each { |row| out.puts(JSON.generate(row)) }
      kept += rows.size
      offset += features.size
      break unless more?(doc, features, page)
    end
    [kept, offset - kept]
  end

  # Servers say there's more at the top (ArcGIS Server) or in properties
  # (ArcGIS Online); a full page means more either way.
  def more?(doc, features, page)
    return false if features.empty?

    doc["exceededTransferLimit"] || doc.dig("properties", "exceededTransferLimit") || features.size >= page
  end

  # The page's highest OBJECTID, after checking it starts past last.
  def moved_on(layer, offset, features, last)
    ids = features.map { |f| f.dig("properties", "OBJECTID").to_i }
    raise "#{URI(layer[:url]).host}: page at #{offset} repeats earlier features" if ids.any? && ids.min <= last

    ids.max || last
  end

  # [answer, page size]: an answer over the size cap is asked for again
  # with half as many features, down to REGIONAL_MIN_PAGE.
  # A server error, timeout or dropped connection (big layers hit passing
  # ones) is tried again, REGIONAL_TRIES times in all, a little later each time.
  def regional_page(layer, offset, page, tries: REGIONAL_TRIES)
    doc = arcgis_get(URI("#{layer[:url]}/query?#{URI.encode_www_form(regional_query(layer, offset, page))}"))
    raise "#{URI(layer[:url]).host}: #{doc.dig("error", "message")} (#{doc.dig("error", "code")})" if doc["error"]

    [doc, page]
  rescue AnswerTooBig
    raise if page <= REGIONAL_MIN_PAGE

    regional_page(layer, offset, page / 2, tries: tries)
  rescue RuntimeError, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError, OpenSSL::SSL::SSLError,
         EOFError, Errno::ECONNRESET
    raise if tries <= 1

    sleep(REGIONAL_RETRY_S * (REGIONAL_TRIES - tries + 1))
    regional_page(layer, offset, page, tries: tries - 1)
  end

  def regional_query(layer, offset, page)
    query = { where: layer.fetch(:where, "1=1"), outFields: ["OBJECTID", layer[:field]].compact.join(","),
              returnGeometry: true, outSR: 4326, geometryPrecision: 7, orderByFields: "OBJECTID", resultOffset: offset,
              resultRecordCount: page, f: "geojson" }
    if layer[:box]
      query.merge!(geometry: layer[:box].join(","), geometryType: "esriGeometryEnvelope", inSR: 4326,
                   spatialRel: "esriSpatialRelIntersects")
    end
    query
  end

  # { "class" =>, "geometry" => } for a polygon of a known class, else nil.
  # Map data is untrusted: oversized or malformed outlines are dropped.
  def regional_row(layer, feature)
    geometry = feature["geometry"]
    klass = layer[:class] || layer[:classes][feature.dig("properties", layer[:field])]
    return nil unless klass && geometry.is_a?(Hash) && %w[Polygon MultiPolygon].include?(geometry["type"]) &&
                      geometry["coordinates"].is_a?(Array)

    vertices = geometry["coordinates"].flatten.size / 2
    vertices <= REGIONAL_MAX_VERTICES ? { "class" => klass, "geometry" => geometry } : nil
  end
end
