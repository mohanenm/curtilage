# frozen_string_literal: true

# How sure the benchmark's numbers are: 95% intervals by resampling sites
# (a bootstrap), for one run's "in caught" and "out taken in", and for the
# difference between two runs on the same sites (benchmark/README.md, "How
# sure the numbers are"). Held-out sites only ever appear in a release
# check, totals only.
module CurtilageBenchmark
  BOOTSTRAP_DRAWS = 2000
  BOOTSTRAP_SEED = 20_261_126

  module_function

  # { [role, view] => { "in" => [mean, low, high], "out" => [...], "sites" => n } } for a saved run.
  def run_intervals(run, views = %w[default core])
    role_intervals(run["sites"].select { |s| s["views"] }, views) { |site, view| site_rates(site, view) }
  end

  # The same, for new minus old on the sites both runs scored.
  def paired_intervals(old, new, views = %w[default core])
    before = old["sites"].select { |s| s["views"] }.to_h { |s| [s["id"], s] }
    sites = new["sites"].select { |s| s["views"] && before[s["id"]] }
    role_intervals(sites, views) do |site, view|
      a = site_rates(before[site["id"]], view)
      b = site_rates(site, view)
      a && b && a.zip(b).map { |x, y| x && y && (y - x) }
    end
  end

  # Per role and view: the block's [in, out] figure for each site, bootstrapped.
  def role_intervals(sites, views)
    sites.group_by { |s| s["role"] }.flat_map do |role, group|
      views.map do |view|
        figures = group.filter_map { |s| yield(s, view) }
        [[role, view], { "sites" => figures.size, "in" => bootstrap(figures.map(&:first).compact),
                         "out" => bootstrap(figures.map(&:last).compact) }]
      end
    end.to_h
  end

  # [in share, out share] of a site's hand-placed points in a view (nil
  # where the view counts none).
  def site_rates(site, view)
    v = site.dig("views", view) or return nil
    [v["in"].positive? ? v["caught"].fdiv(v["in"]) : nil, v["out"].positive? ? v["included"].fdiv(v["out"]) : nil]
  end

  # [mean, 2.5th percentile, 97.5th percentile] of the mean over resampled sites.
  def bootstrap(values)
    return nil if values.empty?

    rng = Random.new(BOOTSTRAP_SEED)
    means = Array.new(BOOTSTRAP_DRAWS) { values.sum { values[rng.rand(values.size)] }.fdiv(values.size) }.sort
    [values.sum.fdiv(values.size), means[(BOOTSTRAP_DRAWS * 0.025).floor], means[(BOOTSTRAP_DRAWS * 0.975).ceil - 1]]
      .map { |x| x.round(3) }
  end

  def interval_lines(intervals)
    pct = ->(t) { t ? format("%<m>.1f%% (%<lo>.1f to %<hi>.1f)", **%i[m lo hi].zip(t.map { |x| 100 * x }).to_h) : "-" }
    intervals.sort.map do |(role, view), r|
      "#{role} #{view} (#{r["sites"]} sites): in #{pct.call(r["in"])}, out #{pct.call(r["out"])}"
    end
  end
end
