# Public benchmark

A small set of public sites that anyone can run curtilage against, so changes to the rules can be judged on numbers anyone can reproduce. It lives in the repository only; none of it ships in the gem.

**What it is:** 66 public sites in 32 states: ten picked one per category in Delaware, 28 seeded random picks from Overture places across 13 place types in eight states (DE, MA, MD, NC, FL, WI, TX, UT), 2 sites whose building is missing from OSM, 2 tuning sites whose map point is off the business (for choosing the right building from an imprecise pin), and 24 held-out sites drawn at random from Overture places in 24 further states, one each (Michigan and Missouri have since gained tuning sites; all labelled blind and sealed: 16 in the second set, 8 in the third, drawn 2026-11-25). Sites have a role: tuning (rules may be tuned on them), validation (the first held-out set, labelled blind, now scored with every run) and held-out (never scored with the rest, never used for tuning, kept for a final check before each release; see [Roles and the held-out rules](#roles-and-the-held-out-rules)). Every tuning and validation site has its tax parcel as an independent baseline (`benchmark:parcels`); the ten Delaware sites also have a hand-drawn reference polygon, an IoU guide only (median 0.41 at 0.9.0), since one polygon measures agreement with whoever drew it.

**Labelled points.** Each site gets points labelled with what is physically there (a parking stall, the drive-through lane, the road past the kerb, a neighbour's lot). **Views** decide which kinds count as in or out for a use: one table per use case, so the same labels score any of them, and the **core** view counts only what every use case agrees on. See [LABELS.md](LABELS.md) for the kinds, the views and how to label. 56 sites are labelled (by one person; some tuning-site labels were corrected after reviewing results, which is why the held-out sites are the unbiased check). On the 25 labelled tuning sites at 0.9.0, the default settings catch 73% of the "in" points and take in 6.0% of the "out" points (the core view 90% and 1.3%); on the 7 validation sites (labelled blind, before they were scored), 47% and 14.5% (core 60% and 8.9%), so the tuning numbers are optimistic. The 24 held-out sites are labelled (blind) and sealed and scored only in a release check: at the check for 0.9.0, 80% and 6.8% (core 85% and 3.6%), against 80% and 23% for a 50 m circle around the pin; the set of 16 scored 77% and 7.8%, the set of 8 87% and 4.6%. A site can be marked `"placeholder": true` (made-up, kept out of the totals) while trying things out.

## Running it

```sh
bundle exec rake benchmark                                  # run every site, print a table
bundle exec rake "benchmark:compare[OLD.json,NEW.json]"     # what changed between two runs
bundle exec rake benchmark:baseline                         # run, and save the numbers as benchmark/baseline.json
bundle exec rake benchmark:label_page                       # write the labelling page (data/benchmark/label.html)
bundle exec rake benchmark:gallery                          # write the gallery (docs/gallery/index.html), over USGS snapshots
CURTILAGE_BENCHMARK_HOLDOUT=1 CURTILAGE_RELEASE_CHECK=1 bundle exec rake benchmark   # held-out totals (release check only)
bundle exec rake benchmark:seal                             # seal newly labelled held-out sites
bundle exec rake "benchmark:review_sample[ID]"              # the four-outcome review sample for one site
bundle exec rake benchmark:parcels                          # fetch each site's tax parcel and those around it (data/benchmark/parcels)
bundle exec rake benchmark:parcel_modes                     # the rules alone and with parcels (clip, grow, start), side by side
bundle exec rake benchmark:flags                            # do flags and confidence mark the poor results? (error by flag, Spearman)
bundle exec rake benchmark:circles                          # 50 m and 75 m circles round the pin, scored the same way (baseline)
bundle exec rake benchmark:diagnose                         # why points are wrong: causes ranked per view, scores by pin quality
```

`benchmark:diagnose` gives every wrong point on the tuning and validation sites a cause (shared-lot split, reach limit, unmapped parking, neighbour cut, a public road between the building and the point, and so on), read from the map data by the heuristics in `benchmark/diagnose.rb`, and ranks the causes by what fixing each would add to the per-site averages. It also splits the scores by where the pin was (on the business's building, beside it, on another building) and by site context (large or shared building). It never looks at held-out sites.

It needs the DuckDB CLI, like the gem (`curtilage doctor` checks). Each run:

- reads each site's map data from the Overture release pinned in `config.json`, once, and caches it under `data/benchmark/cache/<release>/` (gitignored: it's OpenStreetMap data). Later runs are offline and give the same input;
- generates premises with the options in `config.json` (`buildings: osm_or_ml`, what an Overture read gives users by default), plus any `options` a site sets;
- scores each result: whether it passed validation, its overlap (IoU) with the reference and its area against the reference's, its flags, whether it fell back, and how long it took; then totals them overall and per category;
- for each site with labels, scores every view, the points placed by hand and the page's random points apart: the share of its "in" points the premises catch and of its "out" points they take in (averaged per site, so big lots don't count for more), errors overall and beyond 3 m of the edge (within GPS error), sites with a hard failure (a missed building, drive-through or forecourt; a public road, neighbouring building, home or railway taken in), and a tally per kind;
- for each site whose tax parcel was fetched (`benchmark:parcels`, from the state's own parcel service; cached under `data/benchmark/parcels/`, never committed), compares the premises with the parcel, and scores the parcel itself on the labels as if it were the result. Nobody drew parcels for any use of curtilage, so they are a baseline with no convention for shared lots built in. A parcel isn't the premises: it usually stops at the road's right-of-way, short of the kerb, and a shopping centre can be one parcel. Fetching sends each site's location to that state's server;
- prints a table and saves the full run, polygons included, to `data/benchmark/runs/` (gitignored). `benchmark:baseline` also writes `benchmark/baseline.json`, numbers only, which is committed so runs can be compared over time.

### Parcel sources

`benchmark:parcels` fetches, for each tuning and validation site, the parcel under the pin and every parcel within 120 m (for `benchmark:parcel_modes`, which runs the gem with them as `parcels:`). Only geometry is requested; the files stay in `data/benchmark/parcels/`, are never committed, and no parcel is drawn in the gallery. The services, and their terms as each publishes them (checked 2026-11-24; check again before any other use):

| State | Service | Terms as published |
|---|---|---|
| Delaware | FirstMap `DE_StateParcels` | No licence in the service's metadata; FirstMap's disclaimer (as is, at the user's risk). |
| Maryland | MD iMAP `MD_ParcelBoundaries` (Department of Planning, SDAT) | May be freely distributed with its metadata intact; derived works acknowledge the State of Maryland; as is. |
| North Carolina | NC OneMap `NC1Map_Parcels` | Free to use by anyone without restriction (NC OneMap disclaimer); no warranty. |
| Florida | Florida Statewide Cadastral (Department of Revenue tax-roll parcels, on ArcGIS Online) | No licence stated by the service. |
| Wisconsin | Wisconsin Statewide Parcels (State Cartographer's Office) | Free for public download and use; no warranty; not a survey. |
| Texas | TxGIO StratMap Land Parcels | Free of charge; no licence stated; from appraisal districts, which may have their own terms. |
| Utah | UGRC statewide parcels | CC BY 4.0 unless the metadata says otherwise (credit UGRC). |
| Massachusetts | MassGIS Property Tax Parcels | Public domain (MassGIS FAQ). |

IoU against a hand-drawn polygon is only a guide: references often hug the building more tightly than the whole lot curtilage aims for. Look at the preview too (`curtilage preview`) before judging a change.

`benchmark:compare` also lists, per view, how many labelled sites got better, worse or stayed the same (fewer or more wrong points) and which ones. With few sites, that paired count says more than a change in a median.

If Overture retires the pinned release, pin a newer one in `config.json`, run `benchmark:baseline` again, and compare from there.

## Roles and the held-out rules

Every site has a role (`"role"` in `sites.geojson`):

- **tuning**: rules may be judged on these sites, but never on them alone.
- **validation**: sites whose results have been seen, so they're no longer blind. The seven sites held out until 0.7.0 are validation sites now. A rule change is judged on tuning and validation together, and `rake benchmark` prints every view for each role side by side.
- **holdout**: a sealed set for the final check before a release, and nothing else.

The held-out rules:

1. **Labelled before anyone sees results**, on the labelling page, which never shows curtilage's output. Labels are frozen once committed: `rake benchmark:seal` records each file's SHA256 in `holdout_labels.sha256`, and a test fails if a held-out label file differs from its seal or is labelled but unsealed.
2. **Never used for tuning.** `rake benchmark` leaves held-out sites out and only counts them (how many, how many labelled). Scoring them needs both `CURTILAGE_BENCHMARK_HOLDOUT=1` and `CURTILAGE_RELEASE_CHECK=1` and every held-out label sealed; that run scores tuning, validation and held-out sites side by side for every view (each held-out set, `holdout_set` in `sites.geojson`, and all of them together), and prints and saves totals only: nothing per site, per point or per category. The gallery, review pages, diagnosis and parcel tooling skip them.
3. **Replaced only for data problems visible without running the gem**, decided from the site data alone (the Overture place and the map data around it), such as no matching business at the Overture point or a pin far from any building. Every replacement is logged in `holdout_replacements.md` with its reason. From the third set on, a pin that is off the business is kept, as real input often is: the business is labelled where it really is, and the site is replaced only if the business can't be found near the pin at all.

## How the labels were made

Every label in the public benchmark was placed by one person, the project's maintainer, on the labelling page (`rake benchmark:label_page`), over public-domain USGS aerial imagery (NAIP photos, with USGS cached tiles underneath where the photos load slowly), following [LABELS.md](LABELS.md): each point says what is physically there, and the views decide what counts.

| Set | Sites | Labelled | Seen results first? |
|---|---|---|---|
| Tuning | 35 (25 labelled) | over several rounds; some labels corrected after reviewing results (`corrections.csv`) | yes |
| Validation (the first held-out set) | 7 | blind, before any result | no, results seen since |
| Held-out set 2 | 16 | blind; parking re-checked before any result was seen (`holdout_replacements.md`) | no |
| Held-out set 3 | 8 | blind; pins off the business kept and the business labelled where it is | no |

The held-out sets were labelled by the same person who reviews tuning results and directs rule changes, so they share that person's judgement of what counts as the lot. To check that, a random sample of points from each held-out set is to be checked on imagery by a second labeller who has never seen the rules' output, with the agreement rate recorded here and disagreements logged, not fixed (sealed labels never change). No sample has been checked yet.

## Correcting a label

Labels change only to record what's physically there more accurately, never to improve a score. Corrections made while looking at results drift toward them: the corrections log, backfilled from git history (127 changes since the 30-site expansion), shows that, under the core view, 108 raised the score and 10 lowered it.

So every correction to a tuning or validation site:

1. starts with the site's review sample (`rake "benchmark:review_sample[ID]"`): up to five points of each outcome (in caught, in missed, out taken in, out left out) on aerial imagery, so what the rules get right is looked at as closely as what they get wrong;
2. goes into `corrections.csv`: site, point, old and new kind, the reason, what was checked, that the sample was reviewed, and whether it raised or lowered the score under the default and core views. A test fails if a correction logged after the backfill doesn't record the sample as reviewed.

Held-out labels are never corrected (see above).

## Files

- `sites.geojson`: one Point per site, `[lng, lat]`. Properties: `id` (lower-case letters, digits and hyphens), `category`, `notes`, `role` (`tuning`, `validation` or `holdout`), `holdout_set` (held-out sites only), `placeholder` (true for the made-up ones) and optionally `options`, e.g. `{ "buildings": "osm_filled" }` or `{ "preset": "tight" }`.
- `reference/<id>.geojson`: the hand-drawn premises for that site, a GeoJSON Polygon (a Feature or a FeatureCollection whose first feature is it). Any shape; it doesn't have to be convex.
- `labels/<id>.geojson`: the site's labelled points, a FeatureCollection of Points with `kind` and `source` (`hand` or `random`). Made with the labelling page.
- `views/<name>.json`: a view: `name`, `description`, `options` (curtilage options it scores, e.g. `{ "scope": "centre" }`), and the kinds it counts `in` and `out` (the rest are ignored).
- `config.json`: the pinned Overture release and the options every run uses.
- `LABELS.md`: the labelling guide.
- `vendor/leaflet-1.9.4/`: Leaflet (BSD 2-Clause), inlined into the labelling page.
- `runner.rb`, `labels.rb`, `label_page.rb`, `gallery.rb`, `parcels.rb`, `parcel_modes.rb`, `flags_check.rb`, `circles.rb`, `diagnose.rb`, `corrections.rb`, `review_sample.rb`, `check_sites.rb` and `../rakelib/benchmark.rake`: the code.

## Your own sites and views

Set `CURTILAGE_BENCHMARK_DIR` to a folder laid out like this one (`sites.geojson`, `labels/`, `reference/`, `views/`) to score your own sites with the same runner, e.g. a gitignored folder of private sites. Its views are added to the shipped ones (same name: yours wins), so you can score your own use case. In that mode:

- map data is **never fetched**: put each site's features in `cache/<id>.json` as `{ "pin": [lng, lat], "features": [...] }`, from local data, e.g. `Curtilage::Lookup.features(parquet: "data/features/<region>.parquet", pin: pin)` on a local build (`curtilage build`);
- runs are saved in the folder's `runs/`, and `benchmark:baseline` refuses to run;
- `benchmark:label_page` builds the page without imagery, drawing the cached map data instead, unless `ALLOW_IMAGERY=1`: USGS imagery would send the sites' areas to USGS. `LABEL_IMAGERY=off` does the same for the public sites. Either way the page loads nothing but those images (its Content-Security-Policy allows only the two USGS hosts).

## Categories

`standalone`, `corner_lot`, `l_shaped_lot`, `deep_lot` (building set back), `shared_lot` (a few buildings), `shopping_centre_unit`, `backs_onto_houses`, `next_to_railway`, `drive_through`, `fuel_station`, `big_box`, `urban_storefront` (no lot), `outside_us`, `missing_building` (not in OpenStreetMap), and `random` for the seeded random picks (a mix of the above, as they come).

## Adding a site

1. Pick a **public place** that anyone can look up. Never a private or customer site: everything here is public, and running the benchmark sends each site's area to Overture's storage host.
2. If you hold private site lists, check the new site isn't one of them or next to one: `ruby -Ilib benchmark/check_sites.rb PRIVATE_LIST...` fails if any benchmark site is within 1 km of a site in those lists (CSV, GeoJSON points, or JSON with `pin` entries). The lists are only read locally.
3. Add it to `sites.geojson` with its category and a note naming the business and what makes it hard (the labelling page shows the note, so a labeller knows which business "this site" is).
4. Label it on the labelling page (`rake benchmark:label_page`), following [LABELS.md](LABELS.md), without looking at curtilage's output. Save the file as `labels/<id>.geojson`.
5. Fetch its parcel (`rake benchmark:parcels`), run `rake benchmark`, and check the new row.
