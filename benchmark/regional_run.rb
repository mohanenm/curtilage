# frozen_string_literal: true

# Running and scoring the regional check (benchmark/regional/README.md,
# "Metrics"): curtilage on the chosen sites, and the baselines, each scored
# in DuckDB against the official polygons (regional/score.sql).
module CurtilageBenchmark
  REGIONAL_UNCLEAR_SAMPLE = 400  # unclear sites scored, a seeded sample
  REGIONAL_SEED = 20_261_126
  REGIONAL_TOLERANCE_M = 2       # alignment allowance (see the README for how it was set)
  REGIONAL_ENTRANCE_M = 15       # an access point this close to an official entrance matches it
  REGIONAL_BASELINES = %w[circle_50 circle_75 building parcel].freeze

  module_function

  # Phase 4b: each option that might change results on this data, alone,
  # then the combinations chosen from them (benchmark/regional/README.md,
  # "Options"). parcels: true means the region's official parcels.
  REGIONAL_OPTION_RUNS = {
    "partition" => { method: :partition }, "touching_cut" => { touching_neighbours: :cut },
    "notch" => { neighbour_cut: :notch }, "entrances_all" => { entrances: :all },
    "parcels_clip" => { parcels: true, parcel_mode: :clip }, "parcels_grow" => { parcels: true, parcel_mode: :grow },
    "snap_20" => { snap_m: 20 }, "grow_20" => { grow_m: 20 }, "parking_90" => { parking_max_extent_m: 90 },
    "road_offset_9" => { road_offset_m: 9 }, "tight" => { preset: :tight }, "centre" => { scope: :centre },
    "shared_checks" => { shared_checks: true },
    # The combinations the single runs point to (README, "Options").
    "grow_offset_snap" => { parcels: true, parcel_mode: :grow, road_offset_m: 9, snap_m: 20 },
    "clip_snap" => { parcels: true, parcel_mode: :clip, snap_m: 20 }
  }.freeze

  # The region's parcels as GeoParquet (WKB geometry), for parcels: true.
  def regional_parcels(region)
    dir = regional_dir(region)
    out = File.join(dir, "parcels.parquet")
    return out if File.exist?(out)

    source = Curtilage::DuckDB.quote(File.join(dir, "parcels.ndjson"))
    sql = "#{extension_setup} #{Curtilage::DuckDB.load_sql("spatial")} " \
          "COPY (SELECT ST_AsWKB(ST_GeomFromGeoJSON(geometry)) AS geometry FROM read_json(#{source}, " \
          "format = 'newline_delimited', columns = {class: 'VARCHAR', geometry: 'JSON'})) " \
          "TO #{Curtilage::DuckDB.quote(out)} (FORMAT parquet);"
    _, err, status = Curtilage::DuckDB.capture(Curtilage.config.duckdb, sql)
    raise "DuckDB: #{err}" unless status.success?

    out
  end

  # Runs every option in REGIONAL_OPTION_RUNS (or those named); returns the runs.
  def regional_options(region, names = REGIONAL_OPTION_RUNS.keys)
    names.map do |name|
      options = REGIONAL_OPTION_RUNS.fetch(name)
      options = options.merge(parcels: regional_parcels(region)) if options[:parcels] == true
      regional_run(region, label: name, options: options, baselines: false)
    end
  end

  # Every clear site and a seeded sample of the unclear ones.
  def regional_sample(selection)
    clear, unclear = selection.partition { |s| s["group"] == "clear" }
    clear + unclear.sort_by { |s| s["id"] }.sample(REGIONAL_UNCLEAR_SAMPLE, random: Random.new(REGIONAL_SEED))
  end

  # Runs curtilage with options (and, with baselines, the baselines) on the
  # region's sample, scores it and saves the run; returns it.
  def regional_run(region, label: "default", options: {}, baselines: true)
    dir = regional_dir(region)
    sites = regional_sample(JSON.parse(File.read(File.join(dir, "selection.json"), encoding: "utf-8")))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pins = sites.map { |s| [s["lng"], s["lat"]] }
    results = Curtilage.generate_many(pins, **regional_data(region), **options)
    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    rows = sites.zip(results).flat_map { |s, r| regional_rows(s, r, baselines ? REGIONAL_BASELINES : []) }
    scores = regional_score(region, rows)
    run = { "region" => region, "label" => label, "options" => options, "seconds" => seconds,
            "gem_version" => Curtilage::VERSION, "sites" => scores,
            "flags" => sites.zip(results).to_h { |s, r| [s["id"], r.flags.map(&:to_s)] } }
    save_regional_run(dir, run)
  end

  # The region's own OSM build only (built on first use): sites are inside
  # it, and a neighbouring state isn't needed.
  def regional_data(region)
    cache = File.join(regional_dir(region), "cache")
    name = Curtilage::Build.region_path(REGIONAL_AREAS.fetch(region)[:geofabrik]).tr("/", "-")
    built = File.join(cache, "#{name}.parquet")
    File.exist?(built) ? { parquet: built } : { source: :geofabrik, cache_dir: cache }
  end

  # The result, then each baseline, as rows for the scoring query.
  def regional_rows(site, result, baselines)
    base = site.slice("id", "group", "building", "parcel")
    osm = result.details&.dig(:building, :footprint)
    own = { "kind" => "curtilage", "premises" => polygon(result.ring),
            "store" => polygon(result.store_ring), "osm" => polygon(osm),
            "access" => result.details&.dig(:access_points) || [] }
    pin = [site["lng"], site["lat"]]
    extra = baselines.map do |kind|
      premises = case kind
                 when "circle_50" then polygon(circle_ring(pin, 50))
                 when "circle_75" then polygon(circle_ring(pin, 75))
                 when "building" then own["osm"]
                 else site["parcel"]
                 end
      { "kind" => kind, "premises" => premises, "store" => nil, "osm" => own["osm"], "access" => [] }
    end
    ([own] + extra).map { |row| base.merge(row) }
  end

  def polygon(ring) = ring && { "type" => "Polygon", "coordinates" => [ring] }

  def regional_score(region, rows, dir: regional_dir(region))
    Dir.mktmpdir do |tmp|
      results = File.join(tmp, "results.ndjson")
      File.write(results, rows.map { |r| "#{JSON.generate(r)}\n" }.join)
      out = File.join(tmp, "scores.json")
      _, err, status = Curtilage::DuckDB.capture(Curtilage.config.duckdb, regional_score_sql(region, results, out, dir))
      raise "DuckDB: #{err}" unless status.success?

      JSON.parse(File.read(out, encoding: "utf-8"))
    end
  end

  def regional_score_sql(region, results, out, dir)
    regional_sql("score.sql", region, dir, results: Curtilage::DuckDB.quote(results), out: Curtilage::DuckDB.quote(out),
                                           tol: Float(REGIONAL_TOLERANCE_M), entrance_m: REGIONAL_ENTRANCE_M)
  end

  REGIONAL_LEAK_M2 = 10 # a leak this small is within the alignment allowance's noise

  # Per kind and group: site count, medians and the share of sites passing
  # each test, plus structure catch rates. Vintage sites (the official and
  # OSM buildings disagree: IoU under 0.5) are counted and left out.
  def regional_summary(run)
    run["sites"].group_by { |s| [s["kind"], s["group"]] }.sort.map do |(kind, group), rows|
      vintage, rows = rows.partition { |s| s["osm_iou"] && s["osm_iou"] < 0.5 }
      { "kind" => kind, "group" => group, "sites" => rows.size,
        "vintage" => vintage.size }.merge(regional_figures(rows))
    end
  end

  def regional_figures(rows)
    regional_medians(rows).merge(regional_shares(rows), structure_rates(rows),
                                 "entrance_recall" => regional_ratio(rows, "entrances_found", "entrances"),
                                 "entrance_precision" => regional_ratio(rows, "access_right", "access_points"))
  end

  def regional_medians(rows)
    per_area = ->(key) { rows.map { |s| s["area_m2"].to_f.positive? ? s[key] / s["area_m2"] : nil } }
    medians = %w[building_share store_iou pavement_share].to_h { |k| [k, rows.map { |s| s[k] }] }
    medians.merge("road_leak" => per_area.call("road_m2"), "sidewalk_leak" => per_area.call("sidewalk_m2"),
                  "neighbour_leak" => per_area.call("neighbour_m2")).transform_values { |v| regional_median(v) }
  end

  def regional_shares(rows)
    leak = ->(key) { rows.map { |s| s[key].to_f > REGIONAL_LEAK_M2 } }
    { "any_road_leak" => leak.call("road_m2"), "any_sidewalk_leak" => leak.call("sidewalk_m2"),
      "any_neighbour_leak" => leak.call("neighbour_m2"),
      "whole_building" => rows.map { |s| s["building_share"].to_f >= 0.98 },
      "all_in" => rows.map { |s| regional_all_in?(s) },
      "nothing_out" => rows.map { |s| regional_nothing_out?(s) } }.transform_values { |v| regional_share(v) }
  end

  # The share of structures inside the premises, by class: on the site's
  # parcel (should be in) and off it (should be out).
  def structure_rates(rows)
    own, other = rows.flat_map { |s| s["structures"] }.partition { |x| x["own"] }
    inside = ->(xs) { regional_share(xs.map { |x| x["inside"] }) }
    rate = ->(list) { list.group_by { |x| x["class"] }.transform_values(&inside) }
    { "own_structures_in" => rate.call(own), "other_structures_in" => rate.call(other) }
  end

  def regional_median(values) = median(values.compact)
  def regional_share(flags) = flags.empty? ? nil : (flags.count(true).to_f / flags.size).round(3)

  def regional_ratio(rows, part, whole)
    total = rows.sum { |s| s[whole].to_i }
    total.zero? ? nil : (rows.sum { |s| s[part].to_i }.to_f / total).round(3)
  end

  # Everything that should be in: the whole building, nearly all the
  # parcel's pavement, and every structure on the parcel.
  def regional_all_in?(site)
    site["building_share"].to_f >= 0.98 && (site["pavement_share"].nil? || site["pavement_share"] >= 0.9) &&
      site["structures"].select { |x| x["own"] }.all? { |x| x["inside"] }
  end

  # Nothing that should be out: no road or neighbour leak beyond the
  # allowance, and no structure off the parcel.
  def regional_nothing_out?(site)
    site["road_m2"].to_f <= REGIONAL_LEAK_M2 && site["neighbour_m2"].to_f <= REGIONAL_LEAK_M2 &&
      site["structures"].reject { |x| x["own"] }.none? { |x| x["inside"] }
  end

  REGIONAL_COLUMNS = { "whole_building" => "bldg", "pavement_share" => "pave", "any_road_leak" => "road>10",
                       "any_sidewalk_leak" => "walk>10", "any_neighbour_leak" => "nbr>10", "all_in" => "all in",
                       "nothing_out" => "none out", "entrance_recall" => "ent rec",
                       "entrance_precision" => "ent prec" }.freeze

  # The latest saved run for each label in the region (or the files given).
  def regional_runs(region, files = nil)
    files ||= Dir[File.join(regional_dir(region), "runs", "*.json")].group_by { |f| File.basename(f)[16..] }
    files = files.map { |_, fs| fs.max } if files.is_a?(Hash)
    files.map { |f| JSON.parse(File.read(f, encoding: "utf-8")) }
  end

  # One line per run and kind (curtilage, then the baselines of the
  # default run), per group: sites, then each column as a share.
  def regional_table(runs)
    lines = runs.flat_map { |run| regional_summary(run).map { |row| regional_line(run, row) } }.uniq
    header = ["group", "run", "sites", *REGIONAL_COLUMNS.values, "s"]
    rows = [header] + lines.sort_by { |l| [l[0], l[1]] }
    widths = header.each_index.map { |i| rows.map { |l| l[i].size }.max }
    rows.map { |l| l.each_with_index.map { |c, i| c.ljust(widths[i]) }.join("  ").rstrip }
  end

  def regional_line(run, row)
    own = row["kind"] == "curtilage"
    cells = REGIONAL_COLUMNS.keys.map { |k| row[k].nil? ? "-" : format("%.2f", row[k]) }
    [row["group"], own ? run["label"] : row["kind"], row["sites"].to_s, *cells, own ? run["seconds"].to_s : ""]
  end

  # The default run (with baselines) for every region with sites chosen,
  # and all of them pooled; saves the pooled run in data/regional/.
  def regional_all
    regions = REGIONAL_LAYERS.keys.select { |r| File.exist?(File.join(regional_dir(r), "selection.json")) }
    runs = regions.map { |r| regional_run(r) }
    pooled = { "region" => "all", "label" => "default (#{regions.join(", ")})", "seconds" => runs.sum do |r|
      r["seconds"]
    end,
               "sites" => runs.flat_map { |r| r["sites"].map { |s| s.merge("id" => "#{r["region"]}:#{s["id"]}") } } }
    [runs, save_regional_run(File.join(ROOT, "data", "regional"), pooled)]
  end

  # Per kind and group, each column in two runs; then the sites that passed
  # a test in one run and failed it in the other ("all in", "nothing out").
  def regional_compare(old, new)
    before = regional_summary(old).to_h { |r| [[r["kind"], r["group"]], r] }
    lines = regional_summary(new).filter_map do |row|
      was = before[[row["kind"], row["group"]]] or next
      cells = REGIONAL_COLUMNS.map { |k, name| "#{name} #{regional_cell(was[k])} -> #{regional_cell(row[k])}" }
      "#{row["group"]} #{row["kind"]}: #{cells.join(", ")}"
    end
    lines + regional_flips(old, new)
  end

  def regional_cell(value) = value.nil? ? "-" : format("%.2f", value)

  def regional_flips(old, new)
    a = regional_own(old)
    b = regional_own(new)
    common = a.keys & b.keys
    { "all in" => :regional_all_in?, "nothing out" => :regional_nothing_out? }.map do |name, test|
      better = common.count { |id| !send(test, a[id]) && send(test, b[id]) }
      worse = common.count { |id| send(test, a[id]) && !send(test, b[id]) }
      "#{name}: #{better} sites better, #{worse} worse, of #{common.size}"
    end
  end

  # curtilage's own rows by site id, vintage sites left out (as in the summary).
  def regional_own(run)
    rows = run["sites"].select { |s| s["kind"] == "curtilage" && !(s["osm_iou"] && s["osm_iou"] < 0.5) }
    rows.to_h { |s| [s["id"], s] }
  end

  def save_regional_run(dir, run)
    runs = File.join(dir, "runs")
    FileUtils.mkdir_p(runs)
    path = File.join(runs, "#{Time.now.utc.strftime("%Y%m%d-%H%M%S")}-#{run["label"].gsub(/[^\w-]/, "_")}.json")
    File.write(path, JSON.generate(run))
    run.merge("path" => path)
  end
end
