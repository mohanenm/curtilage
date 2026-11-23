# frozen_string_literal: true

module Curtilage
  # Checks an existing premises polygon (hand-drawn, or saved earlier)
  # against the map and against what Curtilage would generate, to find the
  # ones worth a second look.
  module Audit
    Report = Struct.new(:verdict, :reasons, :validation, :generated, :overlap, :road_m, :neighbour_m2,
                        keyword_init: true)

    THRESHOLDS = {
      road_m: 5,             # public road or railway inside the polygon, metres
      neighbour_m2: 25,      # other buildings covered, square metres
      min_overlap: 0.3,      # overlap (IoU) with the generated polygon below this
    }.freeze

    module_function

    # verdict: :invalid (fails validation), :review (see reasons) or :ok.
    # options go to Curtilage.generate.
    def check(pin, ring, features, thresholds: {}, **options)
      limits = THRESHOLDS.merge(thresholds)
      features = Features.new(pin, features) unless features.is_a?(Features)
      validation = Validation.check(pin, ring, **options.fetch(:validation, {}))
      generated = Curtilage.generate(pin, features, **options)
      return Report.new(verdict: :invalid, reasons: validation.errors, validation: validation, generated: generated) \
        unless validation.ok?

      xy = Geometry.counter_clockwise(Geometry.open_ring(Geometry.project(ring, pin)))
      report = measure(xy, features, generated, pin)
      report.validation = validation
      report.reasons = reasons(report, limits) + validation.warnings
      report.verdict = report.reasons.empty? ? :ok : :review
      report
    end

    def measure(xy, features, generated, pin)
      Report.new(generated: generated, overlap: overlap(xy, generated, pin),
                 road_m: road_length(xy, features).round,
                 neighbour_m2: neighbour_area(xy, features, generated.building).round)
    end

    def reasons(report, limits)
      reasons = []
      reasons << "crosses_road" if report.road_m > limits[:road_m]
      reasons << "covers_neighbour" if report.neighbour_m2 > limits[:neighbour_m2]
      reasons << "differs_from_generated" if report.overlap && report.overlap < limits[:min_overlap]
      reasons
    end

    # Intersection over union with the generated polygon, or nil when
    # nothing was generated.
    def overlap(xy, generated, pin)
      return nil unless generated.ok?

      gen = Geometry.counter_clockwise(Geometry.open_ring(Geometry.project(generated.ring, pin)))
      common = Geometry.overlap_area(xy, gen)
      (common / (Geometry.area(xy) + Geometry.area(gen) - common)).round(2)
    end

    # Metres of public road and railway more than 1 m inside the polygon.
    def road_length(xy, features)
      lines = features.public_roads + features.railways
      lines.sum { |line| line.xy.each_cons(2).sum { |a, b| inside_length(xy, a, b) } }
    end

    def inside_length(xy, a, b)
      length = Geometry.distance(a, b)
      n = [length.ceil, 1].max
      inside = n.times.count do |i|
        p = Geometry.lerp(a, b, (i + 0.5) / n)
        Geometry.contains?(xy, p) && Geometry.distance_to_edges(xy, p) > 1
      end
      inside * length / n
    end

    # Area of other buildings (their convex hulls) inside the polygon.
    def neighbour_area(xy, features, building_id)
      features.buildings.sum do |b|
        next 0 if b.id == building_id || Geometry.contains?(b.xy, [0.0, 0.0])

        part = Geometry.clip_convex(xy, b.hull)
        part.size >= 3 ? Geometry.area(part) : 0
      end
    end
  end
end
