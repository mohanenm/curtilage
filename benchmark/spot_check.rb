# frozen_string_literal: true

# The spot-check of held-out labels (benchmark:spot_check_sample and
# benchmark:spot_check_score): a seeded sample of hand-placed points from
# one held-out set, given to a second labeller without their kinds, and the
# agreement between the two. It reads labels only, never results, and never
# changes a sealed label: disagreements are logged in spot_checks.md.
module CurtilageBenchmark
  SPOT_CHECK_PER_SITE = 5

  module_function

  # [{ "point_id", "site", "notes", "point", "from_pin_m" }] without kinds,
  # the same every time for the same set.
  def spot_check_sample(set, per_site: SPOT_CHECK_PER_SITE)
    rng = Random.new(1000 + set)
    held = sites.select { |s| role(s) == "holdout" && s["holdout_set"] == set }
    held.flat_map do |site|
      hand = (labels(site["id"], paths[:labels]) || []).each_with_index.reject { |l, _| l["source"] == "random" }
      hand.sample(per_site, random: rng).sort_by(&:last).map { |l, i| spot_check_point(site, l, i) }
    end
  end

  def spot_check_point(site, label, index)
    x, y = G.project([label["point"]], site["pin"]).first
    { "point_id" => "#{site["id"]}:#{index}", "site" => site["id"], "notes" => site["notes"].to_s,
      "point" => label["point"], "from_pin_m" => [x.round, y.round] }
  end

  # { "points", "kind_agreement", "view_agreement", "disagreements" } for
  # answers ({ point_id => kind }) against the sealed labels; view
  # agreement counts points both put on the same side of the default view
  # (in, out or not scored).
  def spot_check_score(answers, view)
    rows = answers.map do |point_id, kind|
      site, index = point_id.split(":")
      sealed = labels(site, paths[:labels]).fetch(Integer(index))["kind"]
      [point_id, sealed, kind]
    end
    same_side = rows.count { |_, a, b| wanted(view, a) == wanted(view, b) }
    { "points" => rows.size, "kind_agreement" => rows.count { |_, a, b| a == b }.fdiv(rows.size).round(2),
      "view_agreement" => same_side.fdiv(rows.size).round(2), "disagreements" => rows.reject { |_, a, b| a == b } }
  end
end
