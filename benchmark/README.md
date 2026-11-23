# Public benchmark

A small set of public sites that anyone can run curtilage against, so changes to the rules can be judged on numbers anyone can reproduce. It lives in the repository only; none of it ships in the gem.

**What it is today: a regression check, not a measure of accuracy.** Ten public sites in one state (Delaware), one per category, each with one hand-drawn reference polygon drawn to the whole lot. Use it to compare two versions of curtilage on the same sites. It can't tell you how good premises are in general, or compare curtilage with other tools: ten sites in one state are too few, and one polygon per site measures agreement with whoever drew it. The low IoU (median 0.30) partly reflects references drawn larger than the default output.

**Where it's going: labelled points.** Each site gets points labelled with what is physically there (a parking stall, the drive-through lane, the road past the kerb, a neighbour's lot). **Views** decide which kinds count as in or out for a use: one table per use case, so the same labels score any of them. See [LABELS.md](LABELS.md) for the kinds, the views and how to label. The reference polygons stay as a secondary IoU number. Sites for `drive_through`, `l_shaped_lot`, `outside_us` and `missing_building` are still to come. A site can be marked `"placeholder": true` (made-up, kept out of the totals) while trying things out.

## Running it

```sh
bundle exec rake benchmark                                  # run every site, print a table
bundle exec rake "benchmark:compare[OLD.json,NEW.json]"     # what changed between two runs
bundle exec rake benchmark:baseline                         # run, and save the numbers as benchmark/baseline.json
bundle exec rake benchmark:label_page                       # write the labelling page (data/benchmark/label.html)
```

It needs the DuckDB CLI, like the gem (`curtilage doctor` checks). Each run:

- reads each site's map data from the Overture release pinned in `config.json`, once, and caches it under `data/benchmark/cache/<release>/` (gitignored: it's OpenStreetMap data). Later runs are offline and give the same input;
- generates premises with the options in `config.json`, plus any `options` a site sets;
- scores each result: whether it passed validation, its overlap (IoU) with the reference and its area against the reference's, its flags, whether it fell back, and how long it took; then totals them overall and per category;
- for each site with labels, scores every view: the share of its "in" points the premises catch and of its "out" points they take in (averaged per site, so big lots don't count for more), errors overall and beyond 3 m of the edge (within GPS error), sites with a hard failure (a missed entrance, building, drive-through or forecourt; a public road, neighbouring building, home or railway taken in), and a tally per kind;
- prints a table and saves the full run, polygons included, to `data/benchmark/runs/` (gitignored). `benchmark:baseline` also writes `benchmark/baseline.json`, numbers only, which is committed so runs can be compared over time.

IoU against a hand-drawn polygon is only a guide: references often hug the building more tightly than the whole lot curtilage aims for. Look at the preview too (`curtilage preview`) before judging a change.

`benchmark:compare` also lists, per view, how many labelled sites got better, worse or stayed the same (fewer or more wrong points) and which ones. With few sites, that paired count says more than a change in a median.

If Overture retires the pinned release, pin a newer one in `config.json`, run `benchmark:baseline` again, and compare from there.

## Files

- `sites.geojson`: one Point per site, `[lng, lat]`. Properties: `id` (lower-case letters, digits and hyphens), `category`, `notes`, `placeholder` (true for the made-up ones) and optionally `options`, e.g. `{ "buildings": "osm_filled" }` or `{ "preset": "tight" }`.
- `reference/<id>.geojson`: the hand-drawn premises for that site, a GeoJSON Polygon (a Feature or a FeatureCollection whose first feature is it). Any shape; it doesn't have to be convex.
- `labels/<id>.geojson`: the site's labelled points, a FeatureCollection of Points with `kind` and `source` (`hand` or `random`). Made with the labelling page.
- `views/<name>.json`: a view: `name`, `description`, `options` (curtilage options it scores, e.g. `{ "scope": "centre" }`), and the kinds it counts `in` and `out` (the rest are ignored).
- `config.json`: the pinned Overture release and the options every run uses.
- `LABELS.md`: the labelling guide.
- `runner.rb`, `labels.rb`, `label_page.rb`, `check_sites.rb` and `../rakelib/benchmark.rake`: the code.

## Your own sites and views

Set `CURTILAGE_BENCHMARK_DIR` to a folder laid out like this one (`sites.geojson`, `labels/`, `reference/`, `views/`) to score your own sites with the same runner, e.g. a gitignored folder of private sites. Its views are added to the shipped ones (same name: yours wins), so you can score your own use case. In that mode:

- map data is **never fetched**: put each site's features in `cache/<id>.json` as `{ "pin": [lng, lat], "features": [...] }`, from local data, e.g. `Curtilage::Lookup.features(parquet: "data/features/<region>.parquet", pin: pin)` on a local build (`curtilage build`);
- runs are saved in the folder's `runs/`, and `benchmark:baseline` refuses to run;
- `benchmark:label_page` refuses unless `ALLOW_IMAGERY=1`, because the page loads imagery tiles from USGS, which sends the sites' locations there.

## Categories

`standalone`, `corner_lot`, `l_shaped_lot`, `deep_lot` (building set back), `shared_lot` (a few buildings), `shopping_centre_unit`, `backs_onto_houses`, `next_to_railway`, `drive_through`, `fuel_station`, `big_box`, `urban_storefront` (no lot), `outside_us`, `missing_building` (not in OpenStreetMap).

## Adding a site

1. Pick a **public place** that anyone can look up. Never a private or customer site: everything here is public, and running the benchmark sends each site's area to Overture's storage host.
2. If you hold private site lists, check the new site isn't one of them or next to one: `ruby -Ilib benchmark/check_sites.rb PRIVATE_LIST...` fails if any benchmark site is within 1 km of a site in those lists (CSV, GeoJSON points, or JSON with `pin` entries). The lists are only read locally.
3. Add it to `sites.geojson` with its category and a note on what makes it hard.
4. Draw its premises on aerial imagery: the building and its whole customer-facing lot, stopping at the kerb of public roads, at railways and short of neighbours. Save it as `reference/<id>.geojson`. Draw what the site really is, not what curtilage produces.
5. Run `rake benchmark`, check the new row, and look at the site in `curtilage preview --pin LNG,LAT`.
