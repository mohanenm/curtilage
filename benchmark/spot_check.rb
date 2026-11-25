# frozen_string_literal: true

# The spot-check of held-out labels (benchmark:spot_check_sample and
# benchmark:spot_check_score): a seeded sample of 5 hand-placed points per
# site from one sealed held-out set, handed to a second labeller under
# shuffled numbers with no kinds (label files list points grouped by kind,
# so their positions would hint at it), and the agreement between the two.
# It reads labels only, never results, and never changes a sealed label:
# disagreements are logged in spot_checks.md.
module CurtilageBenchmark
  module_function

  # [{ "id", "site", "index", "kind", "point", "from_pin_m" }], the same every
  # time for the same set and labels; ids "1".."n" in a seeded shuffle.
  def spot_check_points(set)
    raise ArgumentError, "the spot-check is for the public benchmark" if paths[:private]

    held = sites.select { |s| role(s) == "holdout" && s["holdout_set"] == set }
    raise ArgumentError, "no held-out set #{set}" if held.empty?
    raise ArgumentError, "held-out labels aren't all sealed" if unsealed.any?

    points = held.flat_map { |site| site_points(site, Random.new((1000 * set) + site["id"].bytes.sum)) }
    points.shuffle(random: Random.new(set)).each_with_index.map { |p, i| p.merge("id" => (i + 1).to_s) }
  end

  def site_points(site, rng)
    hand = (labels(site["id"], paths[:labels]) || []).each_with_index.reject { |l, _| l["source"] == "random" }
    hand.sample(5, random: rng).sort_by(&:last).map do |l, i|
      x, y = G.project([l["point"]], site["pin"]).first
      { "site" => site["id"], "notes" => site["notes"].to_s, "index" => i, "kind" => l["kind"], "point" => l["point"],
        "from_pin_m" => [x.round, y.round] }
    end
  end

  # What the second labeller gets: no kinds, no positions in the label file.
  def spot_check_sample(set) = spot_check_points(set).map { |p| p.except("index", "kind") }

  # { "points", "answered", "kind_agreement", "answered_agreement",
  #   "view_agreement", "disagreements" } for answers ({ id => kind }). An
  # `unclear` answer is a point the second labeller couldn't judge: it
  # counts against kind agreement only. View agreement is over answered
  # points: both on the same side (in, out, not scored) of the view.
  def spot_check_score(set, answers, view)
    points = answered_points(set, answers)
    answered = points.reject { |p| p["answer"] == "unclear" }
    { "points" => points.size, "answered" => answered.size,
      "kind_agreement" => share(points) { |p| p["kind"] == p["answer"] },
      "answered_agreement" => share(answered) { |p| p["kind"] == p["answer"] },
      "view_agreement" => share(answered) { |p| wanted(view, p["kind"]) == wanted(view, p["answer"]) },
      "disagreements" => points.reject { |p| p["kind"] == p["answer"] }.map { |p| disagreement(p) } }
  end

  def answered_points(set, answers)
    points = spot_check_points(set)
    raise ArgumentError, "answers must cover the sample's #{points.size} points" \
      unless answers.keys.sort == points.map { |p| p["id"] }.sort

    points.map { |p| p.merge("answer" => answers.fetch(p["id"])) }
  end

  def share(items, &) = items.empty? ? nil : items.count(&).fdiv(items.size).round(2)

  def disagreement(point)
    { "id" => point["id"], "label" => "#{point["site"]}:#{point["index"]}", "sealed" => point["kind"],
      "answer" => point["answer"] }
  end

  # The second labeller's imagery (public-domain USGS): 240 m round each
  # site's pin and 50 m centred on each point, into dir.
  def spot_check_images(sample, dir)
    FileUtils.mkdir_p(dir)
    sample.uniq { |p| p["site"] }.each do |p|
      file = File.join(dir, "site-#{p["site"]}.jpg")
      File.binwrite(file, snapshot(sites.find { |s| s["id"] == p["site"] }["pin"])) unless File.file?(file)
    end
    sample.each do |p|
      file = File.join(dir, "point-#{p["id"]}.jpg")
      File.binwrite(file, snapshot(p["point"], 25)) unless File.file?(file)
    end
  end
end
