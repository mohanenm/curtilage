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
    run = benchmark.run
    puts benchmark.table(run)
    File.write(File.join(benchmark::DIR, "baseline.json"), "#{JSON.pretty_generate(benchmark.numbers_only(run))}\n")
    puts "", "saved #{benchmark.save(run)} and benchmark/baseline.json"
  end
end
