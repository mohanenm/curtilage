# Public benchmark

A small set of public sites, each with a hand-drawn premises polygon, that anyone can run curtilage against. It covers the hard cases, so changes to the rules can be judged on numbers anyone can reproduce. It lives in the repository only; none of it ships in the gem.

**Status:** ten public sites in Delaware, one per category, chosen from OpenStreetMap data; hand-drawn references, and sites for `drive_through`, `l_shaped_lot`, `outside_us` and `missing_building`, are still to come. Until a site has a reference, it's scored on validity, flags and fallbacks only. A site can also be marked `"placeholder": true` (made-up, kept out of the totals) while trying things out.

## Running it

```sh
bundle exec rake benchmark                                  # run every site, print a table
bundle exec rake "benchmark:compare[OLD.json,NEW.json]"     # what changed between two runs
bundle exec rake benchmark:baseline                         # run, and save the numbers as benchmark/baseline.json
```

It needs the DuckDB CLI, like the gem (`curtilage doctor` checks). Each run:

- reads each site's map data from the Overture release pinned in `config.json`, once, and caches it under `data/benchmark/cache/<release>/` (gitignored: it's OpenStreetMap data). Later runs are offline and give the same input;
- generates premises with the options in `config.json`, plus any `options` a site sets;
- scores each result: whether it passed validation, its overlap (IoU) with the reference and its area against the reference's, its flags, whether it fell back, and how long it took; then totals them overall and per category;
- prints a table and saves the full run, polygons included, to `data/benchmark/runs/` (gitignored). `benchmark:baseline` also writes `benchmark/baseline.json`, numbers only, which is committed so runs can be compared over time.

IoU against a hand-drawn polygon is only a guide: references often hug the building more tightly than the whole lot curtilage aims for. Look at the preview too (`curtilage preview`) before judging a change.

If Overture retires the pinned release, pin a newer one in `config.json`, run `benchmark:baseline` again, and compare from there.

## Files

- `sites.geojson`: one Point per site, `[lng, lat]`. Properties: `id` (lower-case letters, digits and hyphens), `category`, `notes`, `placeholder` (true for the made-up ones) and optionally `options`, e.g. `{ "buildings": "osm_filled" }` or `{ "preset": "tight" }`.
- `reference/<id>.geojson`: the hand-drawn premises for that site, a GeoJSON Polygon (a Feature or a FeatureCollection whose first feature is it). Any shape; it doesn't have to be convex.
- `config.json`: the pinned Overture release and the options every run uses.
- `runner.rb`, `check_sites.rb` and `../rakelib/benchmark.rake`: the code.

## Categories

`standalone`, `corner_lot`, `l_shaped_lot`, `deep_lot` (building set back), `shared_lot` (a few buildings), `shopping_centre_unit`, `backs_onto_houses`, `next_to_railway`, `drive_through`, `fuel_station`, `big_box`, `urban_storefront` (no lot), `outside_us`, `missing_building` (not in OpenStreetMap).

## Adding a site

1. Pick a **public place** that anyone can look up. Never a private or customer site: everything here is public, and running the benchmark sends each site's area to Overture's storage host.
2. If you hold private site lists, check the new site isn't one of them or next to one: `ruby -Ilib benchmark/check_sites.rb PRIVATE_LIST...` fails if any benchmark site is within 1 km of a site in those lists (CSV, GeoJSON points, or JSON with `pin` entries). The lists are only read locally.
3. Add it to `sites.geojson` with its category and a note on what makes it hard.
4. Draw its premises on aerial imagery: the building and its whole customer-facing lot, stopping at the kerb of public roads, at railways and short of neighbours. Save it as `reference/<id>.geojson`. Draw what the site really is, not what curtilage produces.
5. Run `rake benchmark`, check the new row, and look at the site in `curtilage preview --pin LNG,LAT`.
