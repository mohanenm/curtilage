# frozen_string_literal: true

# The circle baseline (rake benchmark:circles): a circle of each radius
# round the pin, scored on the labels like a result, per role and held-out
# set, totals only. Held-out sites come in only with the release check.
module CurtilageBenchmark
  CIRCLE_RADII = [50, 75].freeze

  module_function

  def circle_ring(pin, radius, sides = 64)
    xy = (0...sides).map { |k| [Math.cos(2 * Math::PI * k / sides), Math.sin(2 * Math::PI * k / sides)] }
    ring = G.unproject(xy.map { |x, y| [x * radius, y * radius] }, pin)
    ring + [ring.first]
  end

  def circle_line(name, pairs, radius, view_name, view)
    st = rates(pairs.map { |s, l| score_labels(view, circle_ring(s["pin"], radius), l, s["pin"]) })
    "#{name.ljust(16)} #{pairs.size.to_s.rjust(2)} sites  circle #{radius} m  #{view_name.ljust(7)} " \
      "#{st["in_caught"]} / #{st["out_included"]}"
  end

  # Lines: per group, radius and view, in caught / out taken in.
  def circle_report(sites, views, labels_dir: paths[:labels], radii: CIRCLE_RADII)
    labelled = sites.filter_map { |s| (l = labels(s["id"], labels_dir)) && [s, l] }.to_h { |s, l| [s["id"], [s, l]] }
    role_groups(labelled.values.map(&:first)).flat_map do |name, group|
      pairs = group.map { |s| labelled[s["id"]] }
      radii.product(views.to_a).map { |r, (view_name, view)| circle_line(name, pairs, r, view_name, view) }
    end
  end
end
