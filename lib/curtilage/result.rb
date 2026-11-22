# frozen_string_literal: true

module Curtilage
  # What generation returns for one pin.
  #
  # ring: the premises, [[lng, lat], ...] closed, or nil. store_ring: the
  # building's outline (the store zone), always inside ring, or nil.
  # details: facts about the site (see Generator.details), or nil when no
  # premises were made. features: the map data it was made from (a Features,
  # in metres around pin), kept for previews and debugging; generate_many
  # drops it unless asked (keep_features: true), and it isn't serialised.
  Result = Struct.new(:method_name, :pin, :ring, :store_ring, :explanation, :flags, :validation, :building,
                      :details, :attribution, :features, keyword_init: true) do
    def ok?
      !ring.nil? && validation.ok?
    end

    # Why the premises aren't usable, in words, or nil if they are. With no
    # polygon, the last step says what was missing (usually no building
    # near the pin).
    def problem
      return nil if ok?
      return "no premises: #{explanation.last}" if ring.nil? && explanation.any?

      "not valid: #{validation.errors.join(", ")}"
    end

    # A GeoJSON Feature (as a Hash) with everything about the result in its
    # properties. Show the attribution wherever the polygon is shown.
    # include_store: a FeatureCollection of the premises and the store zone
    # instead, told apart by properties.role. properties: merged into each
    # feature's properties (an id from your own data, say).
    def to_geojson(attribution: self.attribution || Result::OSM_ATTRIBUTION, include_store: false, properties: {})
      list = geojson_features(attribution: attribution, properties: properties)
      include_store ? { type: "FeatureCollection", features: list } : list.first
    end

    # [premises Feature, store Feature] (the store's geometry is nil without
    # a store zone).
    def geojson_features(attribution: self.attribution || Result::OSM_ATTRIBUTION, properties: {})
      premises = {
        type: "Feature",
        geometry: Result.polygon(ring),
        properties: properties.merge(
          role: "premises", ok: ok?, method: method_name, flags: flags, building: building, details: details,
          errors: validation.errors, warnings: validation.warnings, metrics: validation.metrics,
          explanation: explanation, attribution: attribution
        ),
      }
      store = { type: "Feature", geometry: Result.polygon(store_ring),
                properties: properties.merge(role: "store", building: building, attribution: attribution) }
      [premises, store]
    end

    # Well-known text, for databases and spreadsheets.
    def to_wkt = Result.wkt(ring)
    def store_wkt = Result.wkt(store_ring)

    # The premises grown (positive metres) or shrunk (negative) evenly, for a
    # geofence with a margin: [[lng, lat], ...] closed. Corners are rounded
    # when growing. nil if there are no premises or they shrink away.
    def buffered(metres)
      return nil unless ring

      xy = Geometry.counter_clockwise(Geometry.open_ring(Geometry.project(ring, pin)))
      grown = metres.negative? ? Geometry.clip_inside(xy, xy, -metres) : Geometry.round_buffer(xy, metres)
      return nil if grown.size < 3 || Geometry.area(grown) < 1

      out = Geometry.lnglat(Geometry.clean(grown), pin)
      out << out.first
    end

    def self.wkt(ring)
      return nil unless ring

      "POLYGON ((#{ring.map { |lng, lat| "#{lng} #{lat}" }.join(", ")}))"
    end

    def self.polygon(ring)
      ring && { type: "Polygon", coordinates: [ring] }
    end
  end

  Result::OSM_ATTRIBUTION = ["© OpenStreetMap contributors"].freeze
end
