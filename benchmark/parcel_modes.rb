# frozen_string_literal: true

# The parcel modes side by side (rake benchmark:parcel_modes): the rules
# alone, then with the parcels around each site (benchmark:parcels) under
# parcel_mode :clip (a) and :grow (b), on the tuning and
# validation sites, split by whether the site has parcels, with the parcel
# alone scored as the result for comparison. Held-out sites are never run.
module CurtilageBenchmark
  PARCEL_MODE_RUNS = { "rules alone" => nil, "clip (a)" => "clip", "grow (b)" => "grow" }.freeze

  module_function

  # { run name => rows } for every mode (rows as in run["sites"]).
  def parcel_mode_runs(sites, data, config)
    sites = sites.reject { |s| role(s) == "holdout" }
    PARCEL_MODE_RUNS.to_h do |name, mode|
      features = mode ? data.to_h { |id, rows| [id, rows + area_parcel_features(id)] } : data
      cfg = mode ? config.merge("options" => config.fetch("options", {}).merge("parcel_mode" => mode)) : config
      [name, run(sites: sites, features: features, config: cfg)["sites"]]
    end
  end

  # Lines: per role and view, in caught / out taken in for each mode, on the
  # sites with parcels and those without, and the parcel alone.
  def parcel_mode_report(runs, views, with_parcels)
    lines = []
    %w[tuning validation].each do |role|
      [["with parcels", true], ["without parcels", false]].each do |label, has|
        groups = runs.transform_values do |rows|
          rows.select { |r| r["role"] == role && r["views"] && with_parcels.include?(r["id"]) == has }
        end
        n = groups.values.first.size
        next if n.zero?

        lines += ["", "#{role}, #{label} (#{n} sites): in caught / out taken in"]
        lines += views.map { |v| parcel_mode_line(v, groups, has) }
      end
    end
    lines
  end

  def parcel_mode_line(view, groups, has)
    cells = groups.map do |name, rows|
      s = rates(rows.filter_map { |r| r.dig("views", view) })
      "#{name} #{s["in_caught"]} / #{s["out_included"]}"
    end
    if has
      alone = rates(groups.values.first.filter_map { |r| r.dig("parcel", "views", view) })
      cells << "parcel alone #{alone["in_caught"]} / #{alone["out_included"]}" if alone["sites"].positive?
    end
    "  #{view.ljust(8)} #{cells.join("   ")}"
  end
end
