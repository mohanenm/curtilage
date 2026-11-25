# frozen_string_literal: true

# Why points are wrong (rake benchmark:diagnose): every missed "in" point and
# every included "out" point on the tuning and validation sites gets a cause
# of its own (what went wrong at that point) and its site's context (where
# the pin was, and whether the building is large or shared), so the costs
# can be ranked either way. Held-out sites are never diagnosed. The causes
# are heuristics read from the map data, documented in each rule below.
module CurtilageBenchmark
  PIN_BUCKETS = %w[on_right_building beside_right_building wrong_building far_off].freeze

  module_function

  # [{ "id", "role", "pin_bucket", "site_cause", "totals" => { view => [in, out] },
  #    "points" => [{ "view", "kind", "want", "cause" }] }] for every labelled tuning and validation site.
  # Each view is diagnosed on the result its own options give, as the
  # benchmark scores it; hand-placed labels only (random ones are scored
  # apart). The site's pin bucket and context come from the base options.
  def diagnose(sites, data, views, options)
    sites.reject { |s| role(s) == "holdout" }.filter_map do |site|
      labels = hand_labels(site) or next
      base = options.merge(site.fetch("options", {}))
      results = Hash.new do |h, opts|
        h[opts] = Curtilage.generate(site["pin"], data.fetch(site["id"]), **symbolised(opts))
      end
      points = views.flat_map do |name, view|
        view_points(site, results[base.merge(view["options"])], labels, name, view)
      end
      site_diagnosis(site, diagnosis_context(site, results[base], labels), label_totals(labels, views), points)
    end
  end

  def hand_labels(site) = labels(site["id"], paths[:labels])&.reject { |l| l["source"] == "random" }

  def view_points(site, result, labels, name, view)
    context = diagnosis_context(site, result, labels)
    wrong_points(site, result, labels, view).map { |l, want, edge| point_cause(context, name, l, want, edge: edge) }
  end

  def site_diagnosis(site, context, totals, points)
    { "id" => site["id"], "role" => role(site), "pin_bucket" => context[:bucket],
      "site_cause" => site_cause(context), "totals" => totals, "points" => points }
  end

  # { view => [scored in points, scored out points] }.
  def label_totals(labels, views)
    views.transform_values do |view|
      wants = labels.map { |l| wanted(view, l["kind"]) }
      [wants.count(true), wants.count(false)]
    end
  end

  # Site-level facts the causes need.
  def diagnosis_context(site, result, labels)
    parts = result.features&.buildings&.select { |b| b.id == result.building } || []
    # A building can come in parts sharing one id: the rules used the one
    # nearest the pin.
    target = parts.min_by { |b| G.distance_to_edges(G.open_ring(b.xy), [0.0, 0.0]) }
    { site: site, features: result.features, target: target, bucket: pin_bucket(site, result, parts, labels),
      large: large_building?(result, target), shared: result.flags.include?(:shared_lot),
      fallback: result.flags.include?(:fallback) }
  end

  # Whether the pin is on the building the labels name as the business. A
  # label on a canopy counts as right when the rules took the shop beside
  # it: the canopy is part of the lot by design.
  def pin_bucket(site, result, parts, labels)
    quality = result.pin_quality&.dig(:quality)
    return "far_off" if parts.empty? || quality == "far"

    named = labels.select { |l| l["kind"] == "building" }.map { |l| G.project([l["point"]], site["pin"]).first }
    canopies = result.features.buildings.select { |b| Curtilage::Generator::LOT_TYPES.include?(b.category) }
    right = named.any? { |p| (parts + canopies).any? { |b| G.contains?(G.open_ring(b.xy), p) } }
    return "wrong_building" if named.any? && !right

    quality == "on_building" ? "on_right_building" : "beside_right_building"
  end

  def large_building?(result, target)
    return false unless target

    target.area >= Curtilage::Generator::DEFAULTS[:large_building_note_m2] ||
      result.flags.intersect?(%i[store_may_be_unit large_building])
  end

  # [[label, want, near the edge?]] for the labels the result gets wrong
  # under the view (near the edge: within TOLERANCE_M, still counted wrong).
  def wrong_points(site, result, labels, view)
    xy = result.ring && G.counter_clockwise(G.open_ring(G.project(result.ring, site["pin"])))
    labels.filter_map do |l|
      want = wanted(view, l["kind"])
      next if want.nil?

      p = G.project([l["point"]], site["pin"]).first
      inside = !xy.nil? && G.contains?(xy, p)
      [l, want, !xy.nil? && G.distance_to_edges(xy, p) <= TOLERANCE_M] unless inside == want
    end
  end

  def point_cause(context, view, label, want, edge: false)
    cause = if edge then "on the edge (within #{TOLERANCE_M} m)"
            elsif want then missed_cause(context, view, label)
            else included_cause(label)
            end
    { "view" => view, "kind" => label["kind"], "want" => want, "cause" => cause }
  end

  # The site's context: the pin and the building, which everything else
  # rests on (nil when neither is in doubt).
  def site_cause(context)
    case context[:bucket]
    when "wrong_building" then "pin on the wrong building or road"
    when "far_off" then "pin far off (no building near it)"
    else "large or shared building" if context[:large]
    end
  end

  # Causes for a missed "in" point, in order.
  def missed_cause(context, view, label)
    f, target, site = context.values_at(:features, :target, :site)
    return "no building found" unless target
    return "fallback (main rule refused the site)" if context[:fallback]

    p = G.project([label["point"]], site["pin"]).first
    return "centre scope" if view == "centre" && label["kind"].start_with?("centre_")
    return "driveway corridors and entrances" if %w[entrance centre_entrance].include?(label["kind"])
    return "across a public road" if across_a_road?(f, target, p)
    return "reach limit (lot past 60 m)" if G.distance_to_edges(target.rectangle[:corners], p) > 60
    return "shared-lot split" if label["kind"] == "shared_parking_near" || context[:shared]
    return "unmapped parking" if unmapped_parking?(f, label, p)
    return "neighbour cut" if nearer_a_neighbour?(f, target, p)

    "other"
  end

  # A public road between the building's centre and the point: the trim
  # stops there by design, so the label or the road's class is in question.
  def across_a_road?(features, target, point)
    centre = G.centroid(G.open_ring(target.xy))
    features.public_roads.any? do |road|
      road.xy.each_cons(2).any? { |a, b| G.segments_cross?(centre, point, a, b) }
    end
  end

  def unmapped_parking?(features, label, point)
    %w[own_parking forecourt drive_through].include?(label["kind"]) &&
      features.parking.none? { |q| G.contains?(G.open_ring(q.xy), point) }
  end

  def nearer_a_neighbour?(features, target, point)
    mine = G.distance_to_edges(G.open_ring(target.xy), point)
    features.buildings.any? do |b|
      !b.equal?(target) && b.area >= 40 && G.distance_to_edges(G.open_ring(b.xy), point) < [mine, 40].min
    end
  end

  # Causes for an included "out" point, by its kind.
  INCLUDED_CAUSES = {
    "public_road" => "road trim (road width)", "neighbour_lot" => "lot claimed past the site's share",
    "shared_parking_far" => "lot claimed past the site's share", "neighbour_building" => "neighbour cut",
    "centre_building" => "neighbour cut", "residential" => "homes", "open_land" => "growth into open land",
    "railway" => "railway", "service" => "service areas behind the building"
  }.freeze

  def included_cause(label) = INCLUDED_CAUSES.fetch(label["kind"], "other")

  # The cost of each cause: { view => [[cause, missed, included, in gain,
  # out gain], ...] }, where the gains are what fixing every point with that
  # cause would add to in caught and take off out taken in, in the
  # benchmark's per-site averages. Ranked by the larger gain.
  def cause_table(diagnoses)
    diagnoses.flat_map { |d| d["points"] }.group_by { |p| p["view"] }.sort.to_h do |view, ps|
      rows = ps.group_by { |p| p["cause"] }.map { |cause, group| cause_row(diagnoses, view, cause, group) }
      [view, rows.sort_by { |row| -row[3..].max }]
    end
  end

  def cause_row(diagnoses, view, cause, group)
    _, caught, taken = group_score(diagnoses, view)
    _, fixed_caught, fixed_taken = group_score(diagnoses, view) { |p| p["cause"] != cause }
    [cause, group.count { |p| p["want"] }, group.count { |p| !p["want"] }, (fixed_caught.to_f - caught.to_f).round(3),
     (taken.to_f - fixed_taken.to_f).round(3)]
  end

  # Scores split by a site field: { view => { value => [sites, in caught, out taken in] } }.
  def split_scores(diagnoses, field: "pin_bucket")
    views = diagnoses.flat_map { |d| d["totals"].keys }.uniq.sort
    views.to_h do |view|
      groups = diagnoses.group_by { |d| d[field] || "none" }.transform_values { |ds| group_score(ds, view) }
      [view, groups.sort.to_h]
    end
  end

  # [sites, in caught, out taken in], averaged per site as the benchmark
  # averages them.
  # A block keeps only the wrong points it returns true for (the rest count
  # as right).
  def group_score(diagnoses, view, &keep)
    rates = diagnoses.map do |d|
      ins, outs = d["totals"].fetch(view)
      wrong = d["points"].select { |p| p["view"] == view && (keep.nil? || keep.call(p)) }
      missed = wrong.count { |p| p["want"] }
      [ins.zero? ? nil : 1 - missed.fdiv(ins), outs.zero? ? nil : (wrong.size - missed).fdiv(outs)]
    end
    [diagnoses.size, *rates.transpose.map { |r| mean(r.compact) }]
  end

  # The printed report for one role's diagnoses.
  def diagnosis_report(diagnoses)
    lines = cause_table(diagnoses).flat_map do |view, rows|
      ["", "#{view}: cause, points (missed in / taken-in out), gain if fixed (in caught + / out taken -)",
       *rows.map { |c, m, i, gi, go| "  #{c.ljust(38)} #{m} / #{i}   +#{gi} / -#{go}" }]
    end
    %w[pin_bucket site_cause].each do |field|
      lines += ["", "scores by #{field} (sites: in caught / out taken in)"]
      split_scores(diagnoses, field: field).each do |view, groups|
        groups.each do |g, (n, c, o)|
          lines << "  #{view.ljust(8)} #{g.ljust(34)} #{n}: #{c&.round(3)} / #{o&.round(3)}"
        end
      end
    end
    lines
  end
end
