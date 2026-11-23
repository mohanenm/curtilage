# frozen_string_literal: true

require "json"

# Scoring premises against labelled points (see LABELS.md): each label is a
# kind of place, each view maps kinds to in, out or ignored, and a result is
# scored per view on the "in" points it catches and the "out" points it
# takes in.
module CurtilageBenchmark
  KINDS = %w[
    building walkway own_parking drive_through forecourt entrance service landscaping
    shared_parking_near shared_parking_far centre_road sidewalk public_road neighbour_lot
    neighbour_building residential railway open_land construction unclear
  ].freeze
  # Missing one of these, or taking one of these in, fails the site whatever
  # its rates (when the view scores that kind at all).
  MUST_IN = %w[building entrance drive_through forecourt].freeze
  MUST_OUT = %w[public_road neighbour_building residential railway].freeze
  # A wrong point this close to the premises edge is within GPS error.
  TOLERANCE_M = 3
  MAX_LABELS = 500

  module_function

  # Every view in the directories, later directories overriding earlier
  # ones by name: { name => { "options", "in", "out", ... } }.
  def views(*dirs)
    files = dirs.compact.select { |d| File.directory?(d) }.flat_map { |d| Dir[File.join(d, "*.json")].sort }
    files.map { |file| load_view(file) }.to_h { |view| [view["name"], view] }
  end

  def load_view(file)
    view = JSON.parse(File.read(file, encoding: "utf-8"))
    view = view.merge("options" => view.fetch("options", {}), "in" => Array(view["in"]), "out" => Array(view["out"]))
    problem = view_problem(view)
    raise ArgumentError, "#{file}: #{problem}" if problem

    view
  end

  def view_problem(view)
    kinds = view["in"] + view["out"]
    return "name #{view["name"].inspect} must match #{ID.inspect}" unless view["name"].to_s.match?(ID)
    return "unknown kinds #{(kinds - KINDS).join(", ")}" unless (kinds - KINDS).empty?
    return "a kind is both in and out" unless kinds.uniq.size == kinds.size

    "options must be an object" unless view["options"].is_a?(Hash)
  end

  # The site's labels ([{ "kind", "point" => [lng, lat], "source" }]), or
  # nil if it has none.
  def labels(id, dir)
    file = File.join(dir, "#{id}.geojson")
    return nil unless File.file?(file)

    features = JSON.parse(File.read(file, encoding: "utf-8")).fetch("features")
    raise ArgumentError, "#{file}: over #{MAX_LABELS} labels" if features.size > MAX_LABELS

    features.map { |f| label(f, file) }
  end

  def label(feature, file)
    kind = feature.dig("properties", "kind").to_s
    point = feature.dig("geometry", "coordinates")
    raise ArgumentError, "#{file}: unknown kind #{kind.inspect}" unless KINDS.include?(kind)
    unless feature.dig("geometry", "type") == "Point" && Curtilage::Geometry.valid_coordinates?([point])
      raise ArgumentError, "#{file}: each label must be a Point [lng, lat]"
    end

    { "kind" => kind, "point" => point.map { |v| Float(v) }, "source" => feature.dig("properties", "source") || "hand" }
  end

  # One view's score for one result: counts, per-kind tallies, hard
  # failures and the wrong points.
  def score_labels(view, ring, labels, pin)
    xy = ring && G.counter_clockwise(G.open_ring(G.project(ring, pin)))
    score = { "in" => 0, "caught" => 0, "out" => 0, "included" => 0, "wrong_near_edge" => 0, "kinds" => {},
              "hard" => [], "wrong" => [] }
    labels.each do |l|
      if view["in"].include?(l["kind"]) then tally(score, l, true, xy, pin)
      elsif view["out"].include?(l["kind"]) then tally(score, l, false, xy, pin)
      end
    end
    score.merge("hard" => score["hard"].uniq)
  end

  def tally(score, label, want, xy, pin)
    p = G.project([label["point"]], pin).first
    inside = !xy.nil? && G.contains?(xy, p)
    right = inside == want
    score[want ? "in" : "out"] += 1
    score[want ? "caught" : "included"] += 1 if inside
    kind = (score["kinds"][label["kind"]] ||= { "n" => 0, "right" => 0 })
    kind["n"] += 1
    kind["right"] += 1 if right
    wrong(score, label, want, xy && G.distance_to_edges(xy, p)) unless right
  end

  def wrong(score, label, want, edge_m)
    score["wrong_near_edge"] += 1 if edge_m && edge_m <= TOLERANCE_M
    score["wrong"] << label.slice("kind", "point", "source")
    hard = want ? MUST_IN.include?(label["kind"]) : MUST_OUT.include?(label["kind"])
    score["hard"] << "#{want ? "missed" : "took in"} #{label["kind"]}" if hard
  end

  def errors(score) = (score["in"] - score["caught"]) + score["included"]

  # Per view, over the labelled sites: the share of "in" points caught and
  # of "out" points taken in, averaged per site (big lots don't count for
  # more), the same forgiving wrong points within TOLERANCE_M of the edge,
  # sites with a hard failure, and per-kind tallies.
  def label_stats(scores)
    in_rates = scores.select { |s| s["in"].positive? }.map { |s| s["caught"].fdiv(s["in"]) }
    out_rates = scores.select { |s| s["out"].positive? }.map { |s| s["included"].fdiv(s["out"]) }
    total = scores.sum { |s| errors(s) }
    { "sites" => scores.size, "in_caught" => mean(in_rates), "out_included" => mean(out_rates),
      "errors" => total, "errors_beyond_tolerance" => total - scores.sum { |s| s["wrong_near_edge"] },
      "hard_failures" => scores.count { |s| s["hard"].any? }, "kinds" => kind_totals(scores) }
  end

  def kind_totals(scores)
    scores.flat_map { |s| s["kinds"].to_a }.group_by(&:first).sort.to_h do |kind, pairs|
      [kind, { "n" => pairs.sum { |_, t| t["n"] }, "right" => pairs.sum { |_, t| t["right"] } }]
    end
  end

  def label_table(run)
    stats = run.dig("summary", "views") || {}
    return [] if stats.empty?

    head = row("view", "sites", "in caught", "out taken", "errors", "hard fails")
    lines = stats.map do |name, s|
      [row(name, s["sites"], s["in_caught"], s["out_included"],
           "#{s["errors"]} (#{s["errors_beyond_tolerance"]} > #{TOLERANCE_M} m)", s["hard_failures"]),
       "  #{s["kinds"].map { |k, t| "#{k} #{t["right"]}/#{t["n"]}" }.join(", ")}"]
    end
    ["", head, *lines.flatten]
  end

  # Per view, per site labelled in both runs: fewer errors, more, or the
  # same; the sites that changed are listed.
  def label_changes(old, new)
    new["sites"].flat_map { |s| (s["views"] || {}).keys }.uniq.flat_map do |name|
      pairs = error_pairs(old, new, name)
      better, worse = %i[< >].map { |op| pairs.select { |_, x, y| y.send(op, x) } }
      ["", "#{name}: #{better.size} better, #{worse.size} worse, #{pairs.size - better.size - worse.size} same",
       *(better + worse).map { |id, x, y| "  #{id}: errors #{x} -> #{y}" }]
    end
  end

  # [[site id, errors before, errors after]] for sites one view scored in
  # both runs.
  def error_pairs(old, new, name)
    before = old["sites"].to_h { |s| [s["id"], s.dig("views", name)] }
    new["sites"].filter_map do |s|
      a = before[s["id"]]
      b = s.dig("views", name)
      [s["id"], errors(a), errors(b)] if a && b
    end
  end
end
