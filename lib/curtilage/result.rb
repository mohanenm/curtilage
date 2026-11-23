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
  # steps: the explanation as records, one per line, for tools to show or
  # audit (see the reference for the fields).
  # provenance: what the result was made from and with (gem version, data
  # source and release, options, a hash of the map data), so it can be
  # reproduced; it holds no timestamps, so the same inputs give the same
  # output byte for byte.
  Result = Struct.new(:method_name, :pin, :ring, :store_ring, :explanation, :flags, :validation, :building,
                      :details, :attribution, :features, :provenance, :steps, :approach_ring, :pickup_ring,
                      :staging_point, :pin_quality, :candidates, keyword_init: true) do
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

    # [premises Feature, store Feature, then any zones asked for] (the
    # store's geometry is nil without a store zone). properties.role tells
    # them apart: premises, store, approach or pickup.
    def geojson_features(attribution: self.attribution || Result::OSM_ATTRIBUTION, properties: {})
      premises = {
        type: "Feature",
        geometry: Result.polygon(ring),
        properties: properties.merge(
          role: "premises", ok: ok?, pin_quality: pin_quality, confidence: confidence,
          confidence_factors: confidence_factors,
          method: method_name, flags: flags, building: building, details: details,
          errors: validation.errors, warnings: validation.warnings, metrics: validation.metrics,
          explanation: explanation, steps: steps || [], attribution: attribution, provenance: provenance
        ),
      }
      store = { type: "Feature", geometry: Result.polygon(store_ring),
                properties: properties.merge(role: "store", building: building, attribution: attribution) }
      [premises, store] + zone_features(properties.merge(attribution: attribution)) + candidate_features(properties)
    end

    # Each candidate (generate's candidates:) as a Feature of its own, role
    # candidate, rank 1 for the most confident, with everything a premises
    # Feature carries.
    def candidate_features(properties)
      (candidates || []).each_with_index.map do |c, i|
        c.geojson_features(properties: properties).first.tap do |f|
          f[:properties] = f[:properties].merge(role: "candidate", rank: i + 1)
        end
      end
    end

    # The candidates in short, for NDJSON and the like.
    def candidate_summaries
      (candidates || []).each_with_index.map do |c, i|
        { rank: i + 1, geometry: Result.polygon(c.ring), confidence: c.confidence, flags: c.flags,
          building: c.building, method: c.method_name, explanation: c.explanation }
      end
    end

    # The approach and pickup zones and the staging point, when asked for
    # and made. The pickup zone and staging point are always estimated (no
    # source maps pickup spots or entrances).
    def zone_features(properties)
      zones = { "approach" => [Result.polygon(approach_ring), {}],
                "pickup" => [Result.polygon(pickup_ring), { estimated: true }],
                "staging" => [Result.point(staging_point), { estimated: true }] }
      zones.filter_map do |role, (geometry, extra)|
        geometry && { type: "Feature", geometry: geometry, properties: properties.merge(role: role, **extra) }
      end
    end

    # Where vehicles enter from the street: [{ point: [lng, lat], street:,
    # street_class:, street_id:, driveway: }, ...] (details[:entrances]).
    def entrances = details ? details[:entrances] : []

    # Puts a step, and its line of the explanation, before the others (the
    # data source, a failed first attempt).
    def prepend_step(text, step:, **fields)
      explanation.unshift(text)
      (self.steps ||= []).unshift({ step: step, text: text, **fields }.compact)
      self
    end

    # How far to trust the result, 0 to 1 (see Confidence), and the factors
    # behind it: [{ name:, met:, weight: }, ...].
    def confidence = Confidence.assess(self)[0]
    def confidence_factors = Confidence.assess(self)[1]

    # Well-known text, for databases and spreadsheets.
    def to_wkt = Result.wkt(ring)
    def store_wkt = Result.wkt(store_ring)
    def approach_wkt = Result.wkt(approach_ring)
    def pickup_wkt = Result.wkt(pickup_ring)
    def staging_wkt = staging_point && "POINT (#{staging_point.join(" ")})"

    # The premises grown (positive metres) or shrunk (negative) evenly, for a
    # geofence with a margin: [[lng, lat], ...] closed. Corners are rounded
    # when growing. nil if there are no premises or they shrink away.
    # Non-convex premises (entrances: :all) are buffered on a Grid, to within
    # a cell (half a metre to two), keeping the part round the pin.
    def buffered(metres)
      return nil unless ring

      xy = Geometry.counter_clockwise(Geometry.open_ring(Geometry.project(ring, pin)))
      grown = buffered_xy(xy, metres)
      return nil if grown.nil? || grown.size < 3 || Geometry.area(grown) < 1

      out = Geometry.lnglat(Geometry.clean(grown), pin, provenance&.dig(:options, :precision) || 7)
      out << out.first
    end

    def buffered_xy(xy, metres)
      return Geometry.buffer_any(xy, metres, [0.0, 0.0]) unless Geometry.convex?(xy)

      metres.negative? ? Geometry.clip_inside(xy, xy, -metres) : Geometry.round_buffer(xy, metres)
    end

    def self.wkt(ring)
      return nil unless ring

      "POLYGON ((#{ring.map { |lng, lat| "#{lng} #{lat}" }.join(", ")}))"
    end

    def self.polygon(ring)
      ring && { type: "Polygon", coordinates: [ring] }
    end

    def self.point(lnglat)
      lnglat && { type: "Point", coordinates: lnglat }
    end
  end

  Result::OSM_ATTRIBUTION = ["© OpenStreetMap contributors"].freeze
end
