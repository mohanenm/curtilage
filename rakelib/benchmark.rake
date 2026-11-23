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
  desc "Write the labelling page (data/benchmark/label.html, or label.html in CURTILAGE_BENCHMARK_DIR)"
  task :label_page do
    paths = benchmark.paths
    if paths[:private] && ENV["ALLOW_IMAGERY"] != "1"
      abort "The labelling page loads USGS imagery for each site, which sends the sites' locations to USGS. " \
            "Set ALLOW_IMAGERY=1 only if that's allowed for these sites."
    end
    out = File.join(File.dirname(paths[:runs]), "label.html")
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, benchmark.label_page(benchmark.sites, paths[:labels]))
    puts "wrote #{out}: open it in a browser"
  end
end

namespace :benchmark do
  desc "Write the gallery of public benchmark sites (docs/gallery/index.html)"
  task :gallery do
    paths = benchmark.paths
    abort "benchmark:gallery is for the public benchmark only (CURTILAGE_BENCHMARK_DIR is set)" if paths[:private]
    config = benchmark.config
    sites = benchmark.scored_sites
    html = benchmark.gallery(sites, benchmark.features(sites, config.fetch("overture_release")), paths[:labels],
                             benchmark.views(*paths[:views]).fetch("default"), config.fetch("options", {}))
    out = File.expand_path("../docs/gallery/index.html", __dir__)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, html)
    puts "wrote #{out}"
  end
end
