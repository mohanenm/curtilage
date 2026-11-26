# frozen_string_literal: true

# The public benchmark (see benchmark/README.md). Loaded lazily so the
# default test and lint tasks don't touch it.
def benchmark
  require_relative "../benchmark/runner"
  CurtilageBenchmark
end

desc "Run the public benchmark and print the results (writes data/benchmark/runs/*.json)"
task :benchmark do
  run = benchmark.run
  # Held-out (release check): totals only, nothing per site or per point.
  run = benchmark.summary_only(run) if benchmark.holdout_run?
  puts benchmark.table(run)
  puts "", "saved #{benchmark.save(run)}"
end

namespace :benchmark do
  desc "Compare two benchmark runs: rake \"benchmark:compare[OLD.json,NEW.json]\""
  task :compare, %i[old new] do |_, args|
    abort "give two run files" unless args[:old] && args[:new]
    puts benchmark.compare(benchmark.load_run(args[:old]), benchmark.load_run(args[:new]))
  end

  desc "Run the benchmark and save its numbers (no polygons) as benchmark/baseline.json"
  task :baseline do
    if benchmark.paths[:private] || ENV["CURTILAGE_BENCHMARK_HOLDOUT"] == "1"
      abort "benchmark:baseline is for the public benchmark's tuning sites only " \
            "(unset CURTILAGE_BENCHMARK_DIR and CURTILAGE_BENCHMARK_HOLDOUT)"
    end
    run = benchmark.run
    puts benchmark.table(run)
    File.write(File.join(benchmark::DIR, "baseline.json"), "#{JSON.pretty_generate(benchmark.numbers_only(run))}\n")
    puts "", "saved #{benchmark.save(run)} and benchmark/baseline.json"
  end
end

namespace :benchmark do
  desc "Write the labelling page (data/benchmark/label.html, or label.html in CURTILAGE_BENCHMARK_DIR); " \
       "LABEL_IMAGERY=off loads no imagery"
  task :label_page do
    paths = benchmark.paths
    # USGS imagery sends each site's area to USGS: on for the public sites,
    # off for a private folder unless ALLOW_IMAGERY=1.
    imagery = ENV["LABEL_IMAGERY"] != "off" && (!paths[:private] || ENV["ALLOW_IMAGERY"] == "1")
    sites = benchmark.sites
    dir = File.join(paths[:cache], benchmark.config.fetch("overture_release"))
    context = imagery ? {} : sites.to_h { |s| [s["id"], benchmark.cached(dir, s)] }.compact
    out = File.join(File.dirname(paths[:runs]), "label.html")
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, benchmark.label_page(sites, paths[:labels], imagery: imagery, context: context))
    puts "wrote #{out}#{" (imagery off: nothing is loaded from anywhere)" unless imagery}: open it in a browser"
  end
end

namespace :benchmark do
  desc "Write the gallery of public benchmark sites (docs/gallery/index.html)"
  task :gallery do
    paths = benchmark.paths
    abort "benchmark:gallery is for the public benchmark only (CURTILAGE_BENCHMARK_DIR is set)" if paths[:private]
    abort "benchmark:gallery never shows held-out sites: unset CURTILAGE_BENCHMARK_HOLDOUT" if benchmark.holdout_run?
    config = benchmark.config
    sites = benchmark.scored_sites
    out = File.expand_path("../docs/gallery/index.html", __dir__)
    # Public-domain USGS snapshots, fetched once into docs/gallery/images.
    backgrounds = benchmark.snapshots(sites, File.join(File.dirname(out), "images"))
    html = benchmark.gallery(sites, benchmark.features(sites, config.fetch("overture_release")), paths[:labels],
                             benchmark.views(*paths[:views]).fetch("default"), config.fetch("options", {}),
                             backgrounds: backgrounds)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, html)
    puts "wrote #{out}"
  end
end

namespace :benchmark do
  desc "Fetch each public benchmark site's tax parcel from its state's parcel service (into data/benchmark/parcels)"
  task :parcels do
    if benchmark.paths[:private]
      abort "benchmark:parcels is for the public benchmark only (CURTILAGE_BENCHMARK_DIR is set)"
    end
    # Held-out sites are left out with the rest of the per-site tooling.
    sites = benchmark.sites.reject { |s| benchmark.role(s) == "holdout" }
    found = benchmark.fetch_parcels(sites)
    benchmark.fetch_area_parcels(sites)
    found.each do |id, ring|
      puts "#{id}: #{ring ? "parcel" : "none"}, #{benchmark.area_parcel_features(id).size} parcels around it"
    end
  end
end

namespace :benchmark do
  desc "Seal new held-out label files (records their SHA256 in benchmark/holdout_labels.sha256; never changes one)"
  task :seal do
    sealed = benchmark.seal!
    puts sealed.empty? ? "nothing new to seal" : "sealed #{sealed.join(", ")}"
  end
end

namespace :benchmark do
  desc "Write the review sample for one site (all four outcomes on imagery): rake \"benchmark:review_sample[ID,view]\""
  task :review_sample, %i[id view] do |_, args|
    site = benchmark.sites.find { |s| s["id"] == args[:id] } or abort "no site #{args[:id].inspect}"
    view = args[:view] || "default"
    data = benchmark.features([site], benchmark.config.fetch("overture_release"))
    options = benchmark.symbolised(benchmark.config["options"])
    options = options.merge(benchmark.symbolised(site.fetch("options", {})))
    ring = Curtilage.generate(site["pin"], data.fetch(site["id"]), **options).ring
    labels = benchmark.labels(site["id"], benchmark.paths[:labels]) or abort "#{site["id"]} has no labels"
    sample = benchmark.review_sample(site, ring, labels, benchmark.views(*benchmark.paths[:views]).fetch(view))
    out = File.join(File.dirname(benchmark.paths[:runs]), "review-#{site["id"]}.html")
    File.write(out, benchmark.review_page(site, ring, sample, view))
    puts "wrote #{out}: #{sample.map { |o, l| "#{o} #{l.size}" }.join(", ")}"
  end
end

namespace :benchmark do
  desc "Why points are wrong: causes ranked per view, and scores by pin quality (tuning and validation sites)"
  task :diagnose do
    abort "benchmark:diagnose never looks at held-out sites" if benchmark.holdout_run?
    sites = benchmark.sites.reject { |s| benchmark.role(s) == "holdout" }
    data = benchmark.features(sites, benchmark.config.fetch("overture_release"))
    views = benchmark.views(*benchmark.paths[:views])
    diagnoses = benchmark.diagnose(sites, data, views, benchmark.config["options"])
    %w[tuning validation].each do |role|
      ds = diagnoses.select { |d| d["role"] == role }
      puts "", "== #{role} (#{ds.size} sites) ==", benchmark.diagnosis_report(ds)
    end
    out = File.join(File.dirname(benchmark.paths[:runs]), "diagnosis.json")
    File.write(out, JSON.pretty_generate(diagnoses))
    puts "", "saved #{out}"
  end
end

namespace :benchmark do
  desc "Parcel modes side by side (rules alone, clip, grow, start) on tuning and validation sites"
  task :parcel_modes do
    abort "benchmark:parcel_modes never runs held-out sites" if benchmark.holdout_run?
    sites = benchmark.sites.reject { |s| benchmark.role(s) == "holdout" }
    config = benchmark.config
    data = benchmark.features(sites, config.fetch("overture_release"))
    runs = benchmark.parcel_mode_runs(sites, data, config)
    with = sites.map { |s| s["id"] }.select { |id| benchmark.area_parcel_features(id).any? }
    puts benchmark.parcel_mode_report(runs, benchmark.views(*benchmark.paths[:views]).keys, with)
    out = File.join(File.dirname(benchmark.paths[:runs]), "parcel_modes.json")
    File.write(out, JSON.generate(runs.transform_values { |rows| rows.map { |r| r.except("ring") } }))
    puts "", "saved #{out}"
  end
end

namespace :benchmark do
  desc "Do flags and confidence mark the poor results? Error by flag, confidence vs error, per role"
  task :flags do
    sites = benchmark.scored_sites # held-out ones only with the release check
    config = benchmark.config
    data = benchmark.features(sites, config.fetch("overture_release"))
    view = benchmark.views(*benchmark.paths[:views]).fetch("default")
    puts benchmark.flag_report(benchmark.flag_rows(sites, data, config, view))
  end
end

namespace :benchmark do
  desc "Circle baselines (50 m, 75 m) per role and held-out set, default and core views, totals only"
  task :circles do
    views = benchmark.views(*benchmark.paths[:views]).slice("default", "core")
    puts benchmark.circle_report(benchmark.scored_sites, views)
  end
end

namespace :benchmark do
  desc "Spot-check sample of a sealed held-out set, without kinds, with USGS imagery: " \
       "rake \"benchmark:spot_check_sample[3]\""
  task :spot_check_sample, %i[set] do |_, args|
    set = Integer(args[:set] || abort("give the held-out set"))
    dir = File.join(File.dirname(benchmark.paths[:runs]), "spot_check", "set#{set}")
    sample = benchmark.spot_check_sample(set)
    benchmark.spot_check_images(sample, dir)
    File.write(File.join(dir, "sample.json"), "#{JSON.pretty_generate(sample)}\n")
    puts "wrote #{dir}: #{sample.size} points, their imagery and sample.json"
  end

  desc "A second labeller's agreement with the sealed labels: rake \"benchmark:spot_check_score[3,ANSWERS.json]\""
  task :spot_check_score, %i[set answers] do |_, args|
    b = benchmark # loads the benchmark (and json) first
    answers = JSON.parse(File.read(args[:answers] || abort("give the answers file"), encoding: "utf-8"))
    view = b.views(*b.paths[:views]).fetch("default")
    puts JSON.pretty_generate(b.spot_check_score(Integer(args[:set]), answers, view))
  end
end

namespace :benchmark do
  desc "Log uncommitted label corrections, with their effect: rake \"benchmark:log_corrections[REASON,CHECKED,yes]\""
  task :log_corrections, %i[reason checked reviewed] do |_, args|
    unless args[:reviewed] == "yes"
      abort "look at the site's review sample first (rake \"benchmark:review_sample[ID]\"), then pass yes"
    end
    abort "give the reason and what was checked" unless args[:reason] && args[:checked]

    rows = benchmark.pending_corrections(args[:reason], args[:checked])
    abort "no uncommitted changes to tuning or validation labels" if rows.empty?

    benchmark.append_corrections(rows)
    puts "logged #{rows.size} change(s) in benchmark/corrections.csv"
  end
end

namespace :benchmark do
  namespace :regional do
    desc "Fetch a region's official layers for the regional check (data/regional/REGION): " \
         "rake \"benchmark:regional:fetch[dc]\""
    task :fetch, %i[region] do |_, args|
      manifest = benchmark.fetch_regional(args[:region] || "dc")
      manifest.each { |name, m| puts "#{name}: #{m["features"]} features, #{m["fetched_at"]}" }
    end

    desc "Choose a region's sites from Overture places (clear and unclear): rake \"benchmark:regional:sites[dc]\""
    task :sites, %i[region] do |_, args|
      region = args[:region] || "dc"
      benchmark.regional_places(region)
      groups = benchmark.select_regional_sites(region).group_by { |s| s["group"] }
      groups.each { |g, rows| puts "#{g}: #{rows.size}" }
      reasons = groups.fetch("unclear", []).flat_map { |s| s["reasons"] }.tally
      reasons.each { |reason, n| puts "  #{n} #{reason}" }
    end
  end
end

namespace :benchmark do
  namespace :regional do
    desc "Run and score the regional check: rake \"benchmark:regional:run[dc]\""
    task :run, %i[region] do |_, args|
      run = benchmark.regional_run(args[:region] || "dc")
      benchmark.regional_summary(run).each { |row| puts JSON.generate(row) }
      puts "", "saved #{run["path"]} (#{run["seconds"]} s)"
    end

    desc "Side by side: the latest run of each label in a region: rake \"benchmark:regional:table[dc]\""
    task :table, %i[region] do |_, args|
      puts benchmark.regional_table(benchmark.regional_runs(args[:region] || "dc"))
    end

    desc "Run the regional check for each option: rake \"benchmark:regional:options[dc]\" " \
         "(REGIONAL_RUNS=partition,notch for some)"
    task :options, %i[region] do |_, args|
      names = ENV["REGIONAL_RUNS"]&.split(",") || benchmark::REGIONAL_OPTION_RUNS.keys
      benchmark.regional_options(args[:region] || "dc", names).each do |run|
        puts "#{run["label"]}: #{run["path"]} (#{run["seconds"]} s)"
      end
    end
  end
end

namespace :benchmark do
  desc "95% intervals by resampling sites: rake \"benchmark:intervals[RUN.json]\" " \
       "(or [OLD.json,NEW.json] for the difference)"
  task :intervals, %i[old new] do |_, args|
    load = ->(f) { JSON.parse(File.read(f || abort("give a run file"), encoding: "utf-8")) }
    b = benchmark
    old = load.call(args[:old])
    found = args[:new] ? b.paired_intervals(old, load.call(args[:new])) : b.run_intervals(old)
    puts b.interval_lines(found)
  end
end
