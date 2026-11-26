# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "curtilage"
require_relative "labels"
require_relative "label_page"
require_relative "gallery"
require_relative "parcels"
require_relative "corrections"
require_relative "review_sample"
require_relative "diagnose"
require_relative "parcel_modes"
require_relative "flags_check"
require_relative "circles"
require_relative "spot_check"

# The public benchmark (not part of the gem): runs curtilage on the sites in
# benchmark/sites.geojson against a pinned Overture release, scores each
# result against its hand-drawn reference, and compares runs over time.
#
# Map data fetched for each site is cached under data/benchmark/cache (never
# committed: it's OSM data), so later runs are offline and repeatable.
module CurtilageBenchmark
  DIR = __dir__
  ROOT = File.expand_path("..", DIR)
  DATA = File.join(ROOT, "data", "benchmark")
  ID = /\A[a-z0-9][a-z0-9-]{0,63}\z/
  # Options read from JSON whose values are names, not strings.
  SYMBOL_OPTIONS = %w[buildings scope preset method entrances neighbour_cut touching_neighbours parcel_mode].freeze
  G = Curtilage::Geometry

  module_function

  # Where sites, labels, references, views, cached map data and runs live:
  # the public benchmark, or a private folder (CURTILAGE_BENCHMARK_DIR, laid
  # out the same way) whose map data must already be cached there: private
  # sites are never fetched from anywhere.
  def paths(private_dir = ENV.fetch("CURTILAGE_BENCHMARK_DIR", nil))
    if private_dir
      root = File.expand_path(private_dir)
      return { sites: File.join(root, "sites.geojson"), labels: File.join(root, "labels"),
               references: File.join(root, "reference"), views: [File.join(DIR, "views"), File.join(root, "views")],
               cache: File.join(root, "cache"), runs: File.join(root, "runs"), parcels: File.join(root, "parcels"),
               private: true }
    end

    { sites: File.join(DIR, "sites.geojson"), labels: File.join(DIR, "labels"), references: File.join(DIR, "reference"),
      views: [File.join(DIR, "views")], cache: File.join(DATA, "cache"), runs: File.join(DATA, "runs"),
      parcels: File.join(DATA, "parcels"), private: false }
  end

  # config.json, with any options in CURTILAGE_BENCHMARK_OPTIONS (a JSON
  # object, e.g. '{"entrances":"all"}') added for trying a change.
  def config
    config = JSON.parse(File.read(File.join(DIR, "config.json"), encoding: "utf-8"))
    extra = JSON.parse(ENV.fetch("CURTILAGE_BENCHMARK_OPTIONS", "{}"))
    raise ArgumentError, "CURTILAGE_BENCHMARK_OPTIONS must be a JSON object" unless extra.is_a?(Hash)

    config.merge("options" => config.fetch("options", {}).merge(extra))
  end

  # [{ "id", "category", "notes", "placeholder", "options", "pin" }, ...]
  def sites(path = paths[:sites])
    JSON.parse(File.read(path, encoding: "utf-8")).fetch("features").map do |f|
      site = f.fetch("properties").merge("pin" => f.dig("geometry", "coordinates").first(2).map { |v| Float(v) })
      raise ArgumentError, "site id #{site["id"].inspect} must match #{ID.inspect}" unless site["id"].to_s.match?(ID)

      site
    end
  end

  # The reference ring for a site ([[lng, lat], ...]), or nil if none drawn.
  def reference(id, dir = File.join(DIR, "reference"))
    file = File.join(dir, "#{id}.geojson")
    return nil unless File.file?(file)

    doc = JSON.parse(File.read(file, encoding: "utf-8"))
    feature = doc["type"] == "FeatureCollection" ? doc.fetch("features").first : doc
    feature.dig("geometry", "coordinates")&.first
  end

  # { id => raw features }, fetching only the sites not cached for release.
  # A site whose pin moved is fetched again.
  def features(sites, release, cache: paths[:cache],
               fetch: ->(pins) { Curtilage::Overture.features_many(pins, release: release) })
    dir = File.join(cache, release)
    FileUtils.mkdir_p(dir)
    found = sites.to_h { |s| [s["id"], cached(dir, s)] }
    missing = sites.select { |s| found[s["id"]].nil? }
    return found if missing.empty? # everything cached: no network at all

    fetch.call(missing.map { |s| s["pin"] }).zip(missing).each do |rows, site|
      File.write(File.join(dir, "#{site["id"]}.json"), JSON.generate("pin" => site["pin"], "features" => rows))
      found[site["id"]] = rows
    end
    found
  end

  def cached(dir, site)
    file = File.join(dir, "#{site["id"]}.json")
    return nil unless File.file?(file)

    data = JSON.parse(File.read(file, encoding: "utf-8"))
    data["pin"] == site["pin"] ? data["features"] : nil
  end

  # Each site's role: "tuning" (rules may be judged on it, never on it
  # alone), "validation" (seen, no longer blind; judged together with
  # tuning) or "holdout" (sealed: labelled blind, scored only for a release
  # check). Older files mark held-out sites "holdout": true.
  ROLES = %w[tuning validation holdout].freeze
  MIN_SET_SITES = 5

  # { name => sites or rows } by role, with each held-out set beside the
  # combined held-out group when there's more than one ("holdout set 3").
  def role_groups(items)
    groups = items.group_by { |i| role(i) }.sort_by { |name, _| ROLES.index(name) || ROLES.size }.to_h
    sets = groups.fetch("holdout", []).group_by { |i| i["holdout_set"] }
    # A set this small would show per-site results: kept in the combined group only.
    return groups if sets.size < 2 || sets.values.any? { |g| g.size < MIN_SET_SITES }

    groups.merge(sets.sort_by { |s, _| s.to_i }.to_h { |s, g| ["holdout set #{s}", g] })
  end

  def role(site) = site["role"] || (site["holdout"] == true ? "holdout" : "tuning")

  # Tuning and validation sites. Held-out sites only with
  # CURTILAGE_BENCHMARK_HOLDOUT=1 and CURTILAGE_RELEASE_CHECK=1, and then
  # only them.
  # Tuning and validation sites; with the release check (both flags), every
  # site, held-out ones included, once their labels are all sealed. A
  # release-check run keeps totals only (summary_only).
  def scored_sites(all = sites)
    return all.reject { |s| role(s) == "holdout" } unless holdout_run?
    unless release_check?
      raise ArgumentError, "held-out sites are scored only for a release check: set CURTILAGE_RELEASE_CHECK=1 as well"
    end

    problems = unsealed(all)
    raise ArgumentError, "held-out labels aren't all sealed (rake benchmark:seal): #{problems.first(3).inspect}" \
      if problems.any?

    all
  end

  # [held-out sites, how many have labels]: counted, never run.
  def holdout_counts(all = sites)
    held = all.select { |s| role(s) == "holdout" }
    [held.size, held.count { |s| File.file?(File.join(paths[:labels], "#{s["id"]}.geojson")) }]
  end

  SEAL_FILE = File.join(DIR, "holdout_labels.sha256")

  # { "labels/<id>.geojson" => sha256 } from the seal file.
  def seals(file = SEAL_FILE)
    File.readlines(file, chomp: true).grep_v(/\A\s*(#|\z)/).to_h { |line| line.split(/\s+/, 2).reverse }
  end

  # Held-out sites with a label file whose hash differs from its seal, or
  # that has none: [[id, problem], ...]. Empty when every label is sealed.
  def unsealed(all = sites, labels_dir: File.join(DIR, "labels"), file: SEAL_FILE)
    known = seals(file)
    all.select { |s| role(s) == "holdout" }.filter_map do |site|
      path = File.join(labels_dir, "#{site["id"]}.geojson")
      next unless File.file?(path)

      sha = Digest::SHA256.file(path).hexdigest
      seal = known["labels/#{site["id"]}.geojson"]
      next if seal == sha

      [site["id"], seal ? "changed after it was sealed" : "labelled but not sealed (rake benchmark:seal)"]
    end
  end

  # Records the hash of every held-out label file not yet sealed. Never
  # changes an existing seal.
  def seal!(all = sites, labels_dir: File.join(DIR, "labels"), file: SEAL_FILE)
    changed = unsealed(all, labels_dir: labels_dir, file: file).select { |_, why| why.start_with?("changed") }
    raise ArgumentError, "held-out labels changed after sealing: #{changed.map(&:first).join(", ")}" if changed.any?

    new = unsealed(all, labels_dir: labels_dir, file: file).map(&:first)
    File.open(file, "a") do |f|
      new.each { |id| f.puts "#{Digest::SHA256.file(File.join(labels_dir, "#{id}.geojson")).hexdigest}  labels/#{id}.geojson" }
    end
    new
  end

  def holdout_run? = ENV["CURTILAGE_BENCHMARK_HOLDOUT"] == "1"
  def release_check? = ENV["CURTILAGE_RELEASE_CHECK"] == "1"

  # A held-out run keeps only totals: no site, point or category detail
  # anyone could tune against.
  # Per-kind counts go too for held-out groups: a kind found at one site
  # would show that site's result.
  def summary_only(run)
    summary = run["summary"].slice("all", "views", "roles", "parcel")
    roles = summary["roles"]&.to_h do |name, r|
      next [name, r] unless name.start_with?("holdout")

      [name, r.merge("views" => r["views"].transform_values { |v| v.except("kinds") })]
    end
    run.merge("sites" => [], "summary" => summary.merge("roles" => roles).compact)
  end

  def run(sites: scored_sites, features: nil, references: paths[:references], config: self.config,
          labels: paths[:labels], views: self.views(*paths[:views]))
    release = config.fetch("overture_release")
    data = features || self.features(sites, release, **(paths[:private] ? { fetch: method(:refuse_fetch) } : {}))
    rows = sites.map do |site|
      row = run_site(site, data.fetch(site["id"]), references, config.fetch("options", {}))
      site_labels = self.labels(site["id"], labels)
      row.merge(label_scores(site, data.fetch(site["id"]), site_labels, views, config))
         .merge(parcel_scores(site, row["ring"], site_labels, views))
    end
    { "gem_version" => Curtilage::VERSION, "commit" => commit, "overture_release" => release,
      "options" => config.fetch("options", {}), "run_at" => Time.now.utc.iso8601,
      "summary" => summary(rows), "sites" => rows }
  end

  # Private sites' map data must be cached already: never fetched.
  def refuse_fetch(pins)
    raise ArgumentError, "#{pins.size} private site(s) have no cached map data: write <id>.json " \
                         "({ \"pin\": [lng, lat], \"features\": [...] }) into the private cache folder " \
                         "from local data (see benchmark/README.md)"
  end

  def symbolised(options)
    options.to_h { |key, value| [key.to_sym, SYMBOL_OPTIONS.include?(key) ? value.to_sym : value] }
  end

  # { "views" => { name => score } } for a labelled site, one result per
  # distinct set of options the views ask for.
  def label_scores(site, features, labels, views, config)
    return {} unless labels

    results = {}
    scores = views.transform_values do |view|
      opts = config.fetch("options", {}).merge(site.fetch("options", {})).merge(view["options"])
      ring = (results[opts] ||= Curtilage.generate(site["pin"], features, **symbolised(opts))).ring
      score_labels(view, ring, labels, site["pin"])
    end
    { "views" => scores }
  end

  # { "parcel" => metrics } when the site's parcel is cached (rake
  # benchmark:parcels): the premises against it, and the parcel itself
  # scored on the labels as if it were the result.
  def parcel_scores(site, ring, labels, views)
    parcel = parcel(site["id"], site["pin"], paths[:parcels])
    return {} unless parcel

    lot = local(parcel, site["pin"])
    metrics = against(lot, ring && local(ring, site["pin"]))
    if ring
      mine = local(ring, site["pin"])
      metrics["inside_parcel"] = (G.overlap_area(lot, mine) / G.area(mine)).round(3)
    end
    metrics["views"] = views.transform_values { |view| score_labels(view, parcel, labels, site["pin"]) } if labels
    { "parcel" => metrics }
  end

  def run_site(site, features, references, options)
    opts = symbolised(options.merge(site.fetch("options", {})))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Curtilage.generate(site["pin"], features, **opts)
    ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    score(site, result, reference(site["id"], references)).merge("ms" => ms.round(1), "ring" => result.ring)
  end

  # Metrics for one result. IoU and area ratio need a reference; a result
  # with no polygon scores IoU 0 against it.
  def score(site, result, reference)
    row = { "id" => site["id"], "category" => site["category"], "role" => role(site),
            "placeholder" => site["placeholder"] == true,
            "ok" => result.ok?, "method" => result.method_name.to_s,
            "fallback" => result.flags.include?(:fallback), "flags" => result.flags.map(&:to_s),
            "area_m2" => result.validation.metrics[:area_m2] }
    row["holdout_set"] = site["holdout_set"] if site["holdout_set"]
    reference ? row.merge(against(local(reference, site["pin"]), result.ring && local(result.ring, site["pin"]))) : row
  end

  # IoU and area ratio of the generated premises against the reference
  # (both in metres around the pin).
  def against(ref, generated)
    metrics = { "reference_area_m2" => G.area(ref).round }
    return metrics.merge("iou" => 0.0) unless generated

    common = G.overlap_area(ref, generated)
    metrics.merge("iou" => (common / (G.area(generated) + G.area(ref) - common)).round(3),
                  "area_ratio" => (G.area(generated) / G.area(ref)).round(2))
  end

  # Metres around the pin, counter-clockwise, open.
  def local(ring, pin)
    G.counter_clockwise(G.open_ring(G.project(ring, pin)))
  end

  # Placeholder sites are reported apart and never counted in the totals.
  # Label scores ("views", "parcel") are the tuning sites' when there are
  # any, as before; "roles" has each role's views apart.
  def summary(rows)
    real = rows.reject { |r| r["placeholder"] }
    categories = real.group_by { |r| r["category"] }.sort.to_h
    views = real.flat_map { |r| (r["views"] || {}).keys }.uniq
    primary = real.select { |r| r["role"] == "tuning" }
    primary = real if primary.empty?
    { "all" => stats(real), "categories" => categories.transform_values { |r| stats(r) },
      "placeholders" => stats(rows.select { |r| r["placeholder"] }),
      "views" => view_stats(primary, views), "roles" => role_stats(real, views),
      "parcel" => parcel_summary(primary.filter_map { |r| r["parcel"] }, views) }
  end

  def view_stats(rows, views)
    views.to_h { |v| [v, label_stats(rows.filter_map { |r| r.dig("views", v) })] }
  end

  def role_stats(rows, views)
    role_groups(rows).to_h do |role, group|
      labelled = group.count { |r| r["views"] }
      [role, { "sites" => group.size, "labelled" => labelled, "views" => view_stats(group, views) }]
    end
  end

  def parcel_summary(parcels, views)
    { "sites" => parcels.size, "median_iou" => median(parcels.filter_map { |p| p["iou"] }),
      "median_area_ratio" => median(parcels.filter_map { |p| p["area_ratio"] }),
      "median_inside_parcel" => median(parcels.filter_map { |p| p["inside_parcel"] }),
      "views" => views.to_h { |v| [v, label_stats(parcels.filter_map { |p| p.dig("views", v) })] } }
  end

  def stats(rows)
    ious = rows.filter_map { |r| r["iou"] }
    valid = rows.count { |r| r["ok"] }
    { "sites" => rows.size, "valid" => valid, "valid_rate" => rows.empty? ? nil : valid.fdiv(rows.size).round(3),
      "with_reference" => ious.size, "median_iou" => median(ious), "mean_iou" => mean(ious),
      "median_area_ratio" => median(rows.filter_map { |r| r["area_ratio"] }),
      "fallbacks" => rows.count { |r| r["fallback"] }, "flags" => rows.flat_map { |r| r["flags"] }.tally.sort.to_h,
      "total_ms" => rows.sum { |r| r["ms"].to_f }.round }
  end

  def mean(values)
    values.empty? ? nil : (values.sum / values.size).round(3)
  end

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    ((sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0).round(3)
  end

  # The current commit, with "-dirty" when tracked files have changed.
  def commit
    sha, = Open3.capture2("git", "-C", ROOT, "rev-parse", "--short", "HEAD")
    changes, = Open3.capture2("git", "-C", ROOT, "status", "--porcelain", "--untracked-files=no")
    sha.strip.empty? ? "unknown" : "#{sha.strip}#{"-dirty" unless changes.strip.empty?}"
  rescue SystemCallError
    "unknown"
  end

  # Writes the full run (with polygons: OSM-derived, so under data/) and
  # returns its path.
  def save(run, dir: paths[:runs])
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{Time.now.utc.strftime("%Y%m%d-%H%M%S")}-#{run["commit"]}.json")
    File.write(path, JSON.pretty_generate(run))
    path
  end

  # The same run with numbers only (no polygons or points), safe to commit.
  def numbers_only(run)
    run.merge("sites" => run["sites"].map do |s|
      s.except("ring").tap do |c|
        c["views"] &&= c["views"].transform_values do |v|
          v.except("wrong").tap { |w| w["random"] &&= w["random"].except("wrong") }
        end
      end
    end)
  end

  def load_run(path)
    JSON.parse(File.read(path, encoding: "utf-8"))
  end

  def table(run)
    header = "curtilage #{run["gem_version"]} (#{run["commit"]}), Overture #{run["overture_release"]}"
    [header, "", row("category", "sites", "valid", "median IoU", "area ratio", "fallbacks"), *category_rows(run), "",
     row("site", "category", "ok", "IoU", "area ratio", "flags"), *site_rows(run), *label_table(run),
     *parcel_table(run)].join("\n")
  end

  # The premises against each site's tax parcel, and the parcel itself on
  # the labels: what a "use the property line" method would score.
  def parcel_table(run)
    p = run.dig("summary", "parcel")
    return [] unless p && p["sites"].to_i.positive?

    ["", "parcels: #{p["sites"]} sites; premises vs parcel median IoU #{shown(p["median_iou"])}, area ratio " \
         "#{shown(p["median_area_ratio"])}, share of premises inside the parcel #{shown(p["median_inside_parcel"])}",
     *p["views"].reject { |_, s| s["sites"].zero? }.map do |name, s|
       "  the parcel as the result, #{name}: in caught #{s["in_caught"]}, out taken #{s["out_included"]}, " \
         "hard fails #{s["hard_failures"]}/#{s["sites"]}"
     end]
  end

  def category_rows(run)
    (run["summary"]["categories"] || {}).merge("ALL" => run["summary"]["all"]).map do |name, s|
      row(name, s["sites"], s["valid"], s["median_iou"], s["median_area_ratio"], s["fallbacks"])
    end
  end

  def site_rows(run)
    run["sites"].map do |s|
      row("#{s["id"]}#{" (placeholder)" if s["placeholder"]}", s["category"], s["ok"], s["iou"], s["area_ratio"],
          s["flags"].join(" "))
    end
  end

  def row(*cells)
    widths = [32, 22, 6, 11, 11, 0]
    cells.zip(widths).map { |cell, w| (cell.nil? ? "-" : cell.to_s).ljust(w) }.join(" ").rstrip
  end

  # What changed between two runs (full or numbers-only), per site and per
  # category; sites only in one run are listed as added or removed.
  def compare(old, new)
    before = old["sites"].to_h { |s| [s["id"], s] }
    after = new["sites"].to_h { |s| [s["id"], s] }
    sites = (before.keys | after.keys).filter_map do |id|
      change = site_change(before[id], after[id])
      "#{id}: #{change}" if change
    end
    ["#{old["commit"]} -> #{new["commit"]}", "", *sites, "", row("category", "median IoU", "valid"),
     *category_changes(old["summary"], new["summary"]), *label_changes(old, new)].join("\n")
  end

  def category_changes(old, new)
    (old["categories"].keys | new["categories"].keys).push("ALL").map do |name|
      a, b = [old, new].map { |s| name == "ALL" ? s["all"] : s["categories"].fetch(name, {}) }
      row(name, "#{a["median_iou"] || "-"} -> #{b["median_iou"] || "-"}", "#{a["valid"] || 0} -> #{b["valid"] || 0}")
    end
  end

  def site_change(a, b)
    return "added" unless a
    return "removed" unless b

    parts = %w[ok iou area_m2].filter_map { |key| "#{key} #{shown(a[key])} -> #{shown(b[key])}" if a[key] != b[key] }
    { "+" => b["flags"] - a["flags"], "-" => a["flags"] - b["flags"] }.each do |sign, flags|
      parts << "flags #{sign}#{flags.join(" #{sign}")}" unless flags.empty?
    end
    parts.empty? ? nil : parts.join(", ")
  end

  def shown(value)
    value.nil? ? "-" : value
  end
end
