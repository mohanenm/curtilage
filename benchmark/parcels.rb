# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# A second, independent baseline: each site's tax parcel (its legal lot),
# from the state's own public parcel service. Nobody drew it for any use of
# curtilage, so it shows how results compare with property lines, with no
# convention for shared lots built in. A parcel is not the premises (a
# shopping centre can be one parcel, a store's lot several), so it is
# reported beside the labels, never instead of them.
#
# Parcels are fetched into the cache folder, never committed: each state's
# terms differ, and the records hold owner details (only geometry is asked
# for). Fetching sends each site's location to that state's server.
module CurtilageBenchmark
  # Geofabrik region path => the state's parcel layer (ArcGIS REST).
  PARCEL_LAYERS = {
    "north-america/us/delaware" =>
      "https://enterprise.firstmap.delaware.gov/arcgis/rest/services/PlanningCadastre/DE_StateParcels/MapServer/0",
    "north-america/us/maryland" =>
      "https://mdgeodata.md.gov/imap/rest/services/PlanningCadastre/MD_ParcelBoundaries/MapServer/0",
    "north-america/us/north-carolina" => "https://services.nconemap.gov/secure/rest/services/NC1Map_Parcels/MapServer/1",
    "north-america/us/florida" =>
      "https://services9.arcgis.com/Gh9awoU677aKree0/arcgis/rest/services/Florida_Statewide_Cadastral/FeatureServer/0",
    "north-america/us/wisconsin" =>
      "https://services3.arcgis.com/n6uYoouQZW75n5WI/ArcGIS/rest/services/Wisconsin_Statewide_Parcels_DB/FeatureServer/0",
    "north-america/us/texas" =>
      "https://feature.geographic.texas.gov/arcgis/rest/services/Parcels/stratmap_land_parcels_48_most_recent/MapServer/0",
    "north-america/us/utah" =>
      "https://services1.arcgis.com/99lidPhWCzftIe9K/arcgis/rest/services/UtahStatewideParcels/FeatureServer/0",
    "north-america/us/massachusetts" =>
      "https://services1.arcgis.com/hGdibHYSPO59RG1h/ArcGIS/rest/services/Massachusetts_Property_Tax_Parcels/FeatureServer/0",
  }.freeze
  MAX_PARCEL_BYTES = 5_000_000

  module_function

  # Fetches the parcel under each site's pin that isn't cached yet; returns
  # { id => ring or nil }. Sites in states without a layer get nil.
  def fetch_parcels(sites, dir: File.join(DATA, "parcels"), regions: Curtilage::Regions.download.regions)
    FileUtils.mkdir_p(dir)
    sites.to_h do |site|
      file = File.join(dir, "#{site["id"]}.geojson")
      unless File.file?(file)
        layer = PARCEL_LAYERS[regions.find { |r| PARCEL_LAYERS.key?(r.path) && r.covers?(site["pin"]) }&.path]
        next [site["id"], nil] unless layer

        File.write(file, JSON.generate(parcel_doc(layer, site["pin"])))
      end
      [site["id"], parcel(site["id"], site["pin"], dir)]
    end
  end

  # The parcel ring for a site, or nil: the smallest parcel (or part of a
  # multi-part parcel) containing the pin, as stacked condominium parcels
  # repeat the lot.
  def parcel(id, pin, dir = File.join(DATA, "parcels"))
    file = File.join(dir, "#{id}.geojson")
    return nil unless File.file?(file)

    outers = JSON.parse(File.read(file, encoding: "utf-8")).fetch("features", []).flat_map { |f| outer_rings(f) }
    outers.select { |r| r.size >= 4 && Curtilage::Geometry.valid_coordinates?(r) }
          .map { |r| [r, G.open_ring(G.project(r, pin))] }
          .select { |_, xy| G.contains?(xy, [0.0, 0.0]) }
          .min_by { |_, xy| G.area(xy) }&.first
  end

  def outer_rings(feature)
    g = feature["geometry"] || {}
    polygons = { "Polygon" => [g["coordinates"]], "MultiPolygon" => g["coordinates"] }[g["type"]]
    Array(polygons).filter_map { |p| p.is_a?(Array) ? p.first : nil }
  end

  AREA_PARCELS_M = 120

  # Fetches every parcel within AREA_PARCELS_M of each site's pin that
  # isn't cached yet (the site's neighbours too, so split parcels and
  # buildings on several parcels can be handled); returns { id => file or
  # nil }. Held-out sites are the caller's to leave out.
  def fetch_area_parcels(sites, dir: File.join(DATA, "parcels", "area"),
                         regions: Curtilage::Regions.download.regions)
    FileUtils.mkdir_p(dir)
    sites.to_h do |site|
      file = File.join(dir, "#{site["id"]}.geojson")
      unless File.file?(file)
        layer = PARCEL_LAYERS[regions.find { |r| PARCEL_LAYERS.key?(r.path) && r.covers?(site["pin"]) }&.path]
        next [site["id"], nil] unless layer

        begin
          File.write(file, JSON.generate(parcel_doc(layer, site["pin"], box: area_box(site["pin"]))))
        rescue StandardError => e
          warn "#{site["id"]}: #{e.message}"
          next [site["id"], nil]
        end
      end
      [site["id"], file]
    end
  end

  def area_box(pin)
    (w, s), (e, n) = G.unproject([[-AREA_PARCELS_M, -AREA_PARCELS_M], [AREA_PARCELS_M, AREA_PARCELS_M]], pin)
    [w, s, e, n]
  end

  # The cached area parcels as "parcel" features for the gem, or [].
  def area_parcel_features(id, dir = File.join(DATA, "parcels", "area"))
    file = File.join(dir, "#{id}.geojson")
    return [] unless File.file?(file)

    rings = JSON.parse(File.read(file, encoding: "utf-8")).fetch("features", []).flat_map { |f| outer_rings(f) }
    rings.select { |r| r.size >= 4 && Curtilage::Geometry.valid_coordinates?(r) }.each_with_index.map do |r, i|
      { "feature" => "parcel", "id" => "parcel-#{i}", "geometry" => { "type" => "Polygon", "coordinates" => [r] } }
    end
  end

  # Geometry only: anything else a server sends back stays out of the cache.
  # Some servers refuse queries but allow identify (Texas): then that. box:
  # [w, s, e, n] for every parcel in a box instead of the one at the pin.
  def parcel_doc(layer, pin, box: nil)
    fields = { inSR: 4326, spatialRel: "esriSpatialRelIntersects", outFields: "", returnGeometry: true, outSR: 4326,
               f: "geojson" }
    query = URI.encode_www_form(esri_geometry(pin, box).merge(fields))
    doc = arcgis_get(URI("#{layer}/query?#{query}"))
    doc = identify_doc(layer, pin, box) if doc.dig("error", "message").to_s.include?("not supported")
    raise "#{URI(layer).host}: #{doc.dig("error", "message")}" if doc["error"]

    { "type" => "FeatureCollection", "source" => layer,
      "features" => Array(doc["features"]).map { |f| { "type" => "Feature", "geometry" => f["geometry"] } } }
  end

  # A box also asks for outlines simplified to about half a metre: one
  # large tract crossing the box can otherwise run to megabytes.
  def esri_geometry(pin, box)
    return { geometry: box.join(","), geometryType: "esriGeometryEnvelope", maxAllowableOffset: 0.000005 } if box

    { geometry: pin.join(","), geometryType: "esriGeometryPoint" }
  end

  # The identify answer as GeoJSON-like features: each Esri ring a polygon.
  def identify_doc(layer, pin, box = nil)
    service, id = layer.match(%r{\A(.+)/(\d+)\z}).captures
    x, y = pin
    extent = box || [x - 0.001, y - 0.001, x + 0.001, y + 0.001]
    fields = { sr: 4326, layers: "all:#{id}", tolerance: 0, returnGeometry: true, f: "json",
               mapExtent: extent.join(","), imageDisplay: "400,400,96" }
    form = URI.encode_www_form(esri_geometry(pin, box).merge(fields))
    doc = arcgis_get(URI("#{service}/identify?#{form}"))
    return doc if doc["error"]

    rings = Array(doc["results"]).flat_map { |r| Array(r.dig("geometry", "rings")) }
    { "features" => rings.map { |ring| { "geometry" => { "type" => "Polygon", "coordinates" => [ring] } } } }
  end

  def arcgis_get(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 60) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    body = response.body.to_s
    raise "#{uri.host}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    raise "#{uri.host}: answer over #{MAX_PARCEL_BYTES} bytes" if body.bytesize > MAX_PARCEL_BYTES

    JSON.parse(body)
  end
end
