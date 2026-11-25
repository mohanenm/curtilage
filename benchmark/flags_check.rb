# frozen_string_literal: true

# Do the flags and confidence say honestly where results are poor? (rake
# benchmark:flags.) Per tuning and validation site: the share of its
# default-view points that are wrong, beside the result's flags and
# confidence; then per role, the mean error with and without each flag and
# the rank correlation between confidence and error (Spearman; honest
# confidence is strongly negative). Held-out sites come in only with the
# release check, and then only as totals.
module CurtilageBenchmark
  HONESTY_FLAGS = %i[large_building store_may_be_unit shared_lot].freeze

  module_function

  # [{ "id", "role", "error", "confidence", "flags" }] for labelled sites.
  # Held-out sites come in only with the release check (scored_sites).
  def flag_rows(sites, data, config, view)
    sites.filter_map do |site|
      labels = labels(site["id"], paths[:labels]) or next
      opts = config.fetch("options", {}).merge(site.fetch("options", {})).merge(view["options"])
      result = Curtilage.generate(site["pin"], data.fetch(site["id"]), **symbolised(opts))
      error = point_error(score_labels(view, result.ring, labels, site["pin"])) or next
      { "id" => site["id"], "role" => role(site), "error" => error, "confidence" => result.confidence,
        "flags" => result.flags.map(&:to_s) }
    end
  end

  # The share of scored points that are wrong, or nil with none scored.
  def point_error(score)
    total = score["in"] + score["out"]
    total.zero? ? nil : point_errors(score).fdiv(total).round(3)
  end

  def flag_report(rows)
    rows.group_by { |r| r["role"] }.sort.flat_map do |role, rs|
      ["", "#{role} (#{rs.size} sites): mean error with / without each flag",
       *HONESTY_FLAGS.map { |flag| flag_line(rs, flag.to_s) },
       "  confidence vs error (Spearman): #{spearman(rs.map { |r| r["confidence"] }, rs.map { |r| r["error"] })}",
       *(role == "holdout" ? [] : ["  worst sites: #{worst(rs)}"])] # held-out: totals only
    end
  end

  def worst(rows)
    rows.max_by(5) { |r| r["error"] }.map { |r| "#{r["id"]} #{r["error"]} (#{r["confidence"]})" }.join(", ")
  end

  def flag_line(rows, flag)
    with, without = rows.partition { |r| r["flags"].include?(flag) }
    "  #{flag.ljust(18)} #{with.size}: #{mean(with.map { |r| r["error"] })} / " \
      "#{without.size}: #{mean(without.map { |r| r["error"] })}"
  end

  def spearman(first, second)
    return nil if first.size < 3

    rx = ranks(first)
    ry = ranks(second)
    mx = rx.sum / rx.size
    my = ry.sum / ry.size
    cov = rx.zip(ry).sum { |a, b| (a - mx) * (b - my) }
    sd = Math.sqrt(rx.sum { |a| (a - mx)**2 } * ry.sum { |b| (b - my)**2 })
    sd.zero? ? nil : (cov / sd).round(2)
  end

  # Average ranks (ties share theirs).
  def ranks(values)
    order = values.each_index.sort_by { |i| values[i] }
    out = Array.new(values.size)
    start = 0
    order.chunk_while { |a, b| values[a] == values[b] }.each do |group|
      group.each { |i| out[i] = start + ((group.size - 1) / 2.0) }
      start += group.size
    end
    out
  end
end
