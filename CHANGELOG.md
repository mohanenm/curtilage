# Changelog

## [Unreleased]

### Added

- `scope: :centre` finds centres whose lot OSM maps only as aisles: the service roads joined to the site's (within 150 m, not alleys behind homes), when three or more businesses front them, outlined round those strips and buildings rather than as a convex hull. On 24 unseen public sites rated by eye with the arrival settings, sites accepted as they are went from 14 to 19 (none got worse).
- `centre_max_m2` (default 50,000 m2): with `scope: :centre`, a bigger centre (a regional mall) keeps the site's own share instead, flagged `large_centre`.
- `Preview.html(backgrounds:, background_credit:)`: an image per site drawn under its map, from the page's own folder only. The gallery uses it to draw every site over a public-domain USGS aerial snapshot, fetched once when it's built and stored with the page, so the published page still loads nothing from anywhere.
- `CONTRIBUTING.md` (setup, tests, the benchmark, the no-real-site-data rule, how to report a bad polygon), issue templates (bad polygon, bug, feature request) and a pull request checklist, a code of conduct (Contributor Covenant 2.1) and a governance note. The README's Versioning section lists what 1.0 waits for.

### Changed

- `scope: :centre` never counts homes as part of a centre, and needs three or more businesses besides the site: a lot shared only with houses is no longer mapped as a "shopping centre".
- README: held-out results on all 7 held-out sites (default view 47% of "in" points caught, 14.5% of "out" points taken in).
- Public benchmark: two held-out sites are replaced by new seeded random picks, as their Overture points were far from the business (no gas station within 45 m of `md-gas-station`; the store 160 m from `nc-pharmacy`'s): `md-gas-station-2` and `nc-pharmacy-2`.

### Fixed

- A download cut short in transit is retried instead of used: a body shorter than its declared length is a network hiccup, and the Geofabrik region index, Overture's catalogue and Overture's file index are checked whole (they must parse, or be complete Parquet) before they're trusted. A truncated region index used to fail the run with "unreadable Geofabrik region index".
- `SECURITY.md` and `docs/security.md` name the HTTP API, the benchmark tooling's hosts and NDJSON input.

## [0.6.0] - 2026-11-24

Benchmark numbers below were measured on the labels as they stood at each change; the README has the current totals.

### Added

- Public benchmark: 30 new public sites in seven more states (28 seeded random picks, a quarter held out for a final check and never scored with the rest; 2 with buildings missing from OSM), labels for most of them, a **core** view that counts only what every use case agrees on, label kinds `centre_building` and `centre_entrance`, and each site's tax parcel from its state's parcel service as an independent baseline (`rake benchmark:parcels`). A missed entrance now counts as a missed point, not a failed site, and the benchmark generates with `buildings: :osm_or_ml`, as Overture reads do for users.
- Labelling page: Leaflet bundled, a Content-Security-Policy allowing images from the two USGS hosts only, a no-imagery mode (`LABEL_IMAGERY=off`, the default for a private benchmark folder), and each site's business shown. The gallery refuses any site that isn't in the public benchmark, and covers every public site but the held-out ones.
- `neighbour_cut: :notch` (experimental, off by default): cuts round a neighbouring building instead of straight across the premises, so a lot running past a neighbour keeps the part beyond it.

### Changed

- A lot counts as shared only with buildings within 5 m of it (`lot_share_reach_m`, new), not every building within 20 m (`parking_reach_m`, which still decides whether a lot is the site's). Buildings across an aisle or behind the lot no longer split it, so more of a site's own parking is taken in. On the public benchmark's labels: own-parking points caught 306 to 316 of 413, with no more far shared parking taken in. `lot_share_reach_m: 20` restores the old behaviour.
- Lots that OpenStreetMap maps only as service roads (aisles and driveways, no parking area drawn) are taken in: a 9 m strip either side of each service road near the building counts as parking (`aisle_m`, new; `aisle_m: nil` turns it off). On the public benchmark's labels: own-parking points caught 316 to 335 of 413, the share of uncontested "in" points caught 67.5% to 70.9%, with no more roads, homes, neighbours' lots or far shared parking taken in.
- A pin on a canopy (fuel pumps or a drive-through roof, mapped as `building=roof`) now means the building beside it, within 15 m: that's the store, and the canopy part of its lot. The shop was treated as a neighbour, so a fuel station's premises stopped short of its own forecourt.
- Premises reach closer to the kerb: the half road widths by class are measured on the public benchmark's labels instead of guessed, and set halfway back toward the old figures, as OSM centrelines are often off-centre. Trunk 10 to 8.5 m, primary 9 to 7.5, secondary 8 to 7, tertiary 7 to 6, residential 5 to 4.5. Entrances caught on the labels went from 21 to 26 of 65, with one road point of 329 taken in.
- Premises stop at the edge of mapped parking that isn't the site's (another business's lot), as they stop short of a neighbour's building; the cut never removes the site's own claimed lot. A store takes a share of a shared lot only when it fronts it (within `lot_share_reach_m`), not across an aisle or a planting strip. On the public benchmark's labels, neighbours' lot points taken in fell from 18 of 75 to 12.
- New flag `shared_lot` when a lot shared with other buildings is split between them (where it really divides isn't in the map), and a matching confidence factor `own_lot` (weight 0.10).
- Faster: the driveway search measures only the roads near each driveway. Median time per site on the benchmark 25 ms to 17 ms without aisle strips, 32 ms with them (results unchanged).

## [0.5.0] - 2026-11-23

### Added

- A gallery of the public benchmark sites (`docs/gallery/index.html`, `rake benchmark:gallery`): each site's premises, zones, flags and steps, with what its labels say it got wrong. `Preview.html` takes `notes:`, a line of text per site.
- `curtilage missing-buildings`: sites where OpenStreetMap has no building near the pin, as GeoJSON points for mappers (`--maproulette` for MapRoulette's line-by-line format). Uses OSM buildings only; site ids only with `--with-ids`. `Curtilage::MissingBuildings` in Ruby.
- H3 cells: `--h3 RES` / `Curtilage::H3.cover(results, res)` lists the cells each premises touches, in every output, through DuckDB's community `h3` extension (opt-in; installed only when used; published for DuckDB 1.4 LTS at the time of writing).
- `Curtilage.point_in_premises?(ring, point)`: the geofence check on a stored ring.
- `curtilage serve`: an HTTP API (`POST /premises`, `GET /health`, `GET /version`) on the standard library, spec in `docs/openapi.yaml`. Binds 127.0.0.1 unless `--host`; optional bearer token from an environment variable; body, pin, time and concurrency limits; no CORS unless configured; pins never logged unless `--log-pins`. The Docker image exposes 8754 with a health check.
- GeoParquet, GeoPackage and FlatGeobuf output (`--out FILE.parquet|.gpkg|.fgb`, or `--format`), written through DuckDB with attribution and provenance as columns; `--resume` works for them.
- Geofence shapes: `Result#enclosing_circle` and `#fit_circle` (also in GeoJSON/NDJSON properties and new CSV columns), and `Result#simplified(max)` / `--simplify N`, which never drops the pin or store zone.
- `entrances: :all` (experimental, off by default): follows the mapped service roads from the lot to every entrance on a public road and adds a corridor along each, up to the kerb. The premises are then usually not convex. On the public benchmark's labels it takes in 12 of 24 labelled entrances (5 by default) without taking in more of what should stay out.
- Parcels you supply (`parcels:` on `generate_many`, `--parcels FILE`, or `"parcel"` features): premises are clipped to the building's parcel, keeping the site's parking where it clearly runs past it (flag `beyond_parcel`). GeoJSON or GeoParquet, local or at a URL; nothing is fetched on its own.
- `unit_m:` (off by default): the store zone of a large, shared building estimated as that much of its frontage round the pin (flag `unit_estimated`).
- `buildings: :osm_or_ml`: machine-learned footprints only when OpenStreetMap has no building under or near the pin, so every other site is exactly as with `:osm`. The "no building" hint now suggests it.
- `lot_split: :voronoi` (experimental, off by default): splits a shared lot by nearest building wall instead of cuts square to the building.
- `--entrances near|all` on the command line.
- The public benchmark scores labelled points per use case (views), with a labelling page; see `benchmark/LABELS.md`.

### Changed

- Sites read from Overture (`source: :overture`, and `:auto`'s scattered pins) now default to `buildings: :osm_or_ml`: where OpenStreetMap has no building near the pin, Overture's machine-learned footprints are used (flagged `ml_footprint`). Every site with an OSM building comes out as before. Pass `buildings: :osm` for the old behaviour.
- Everything that reads premises (store and pickup zones, `details`, `Audit`, `Diff`, `Result#buffered`) works on non-convex shapes. `Diff` compares a hand-drawn non-convex polygon exactly instead of by its convex outline. Convex results are unchanged.

## [0.4.0] - 2026-11-23

### Breaking

- Command-line exit codes: bad input and usage errors exit 2 (they exited 1, which now only means some sites failed), a missing DuckDB exits 3 and unavailable map data 4. `preview` exits 1 when some sites have no usable premises (it always exited 0), and prints its summary to standard error instead of standard output.

### Added

- Every result records its provenance (`Result#provenance`, the GeoJSON `provenance` property): gem version, data source and release (the Overture release, or each region's Geofabrik extract dates and ML footprints), every option after defaults, and a SHA256 of the map data used. CSV gains `gem_version`, `data_source`, `data_release` and `features_sha256` columns at the end; KML descriptions name the version and release. Outputs hold no timestamps, so the same inputs give the same output byte for byte.
- NDJSON in and out: `--format ndjson` writes one GeoJSON Feature per site per line, following a versioned JSON Schema (`docs/schema/site-v1.json`, shipped in the gem); `--in` reads NDJSON pins, and `--in -` reads them from standard input (`--in-format` picks another format).
- Documented exit codes for `generate`, `preview` and `build`: 0 ok, 1 some sites failed, 2 bad input or usage, 3 DuckDB missing, 4 map data unavailable, 70 unexpected error. `--quiet` and `--log-format json` for what goes to standard error. A missing DuckDB raises `Curtilage::DependencyError`.
- Every result has a confidence from 0 to 1 (`Result#confidence`) with the factors behind it (`Result#confidence_factors`): rule-based, each unmet factor (fallback used, pin off the building, no mapped parking, no road frontage, homes next door, ...) takes a documented weight off 1. It's in GeoJSON, NDJSON, CSV and KML; `curtilage generate --min-confidence N` leaves out results below N, and the preview can sort by it.
- Every result's explanation also comes as structured steps (`Result#steps`, `steps` in GeoJSON and NDJSON): step name, the option that set its distance, the map-data ids involved, the distance used, and the premises area before and after. The explanation gains one line where the lot is added, with the areas.
- Optional zones for arrival detection, nested with the premises: an approach zone (`approach_m:`, `--approach`, the premises grown by 150 m by default) and an estimated pickup zone (`pickup_m:`, `--pickup`, mapped parking within 25 m of the building, inside the premises). In every output format and the preview.
- Driveway entrances name the street they open onto (`details[:entrances]`, `Result#entrances`: point, street name and class, driveway id), shown in KML and on the preview. With a pickup zone, an estimated staging point (`Result#staging_point`) where a driver might wait.
- Pin quality on every result (`Result#pin_quality`: on a building, on a road, near a building or far, with the distance to the nearest building), and optional snapping (`snap_m:`, `--snap`): a pin off any building moves onto the nearest one, flagged `pin_moved`, so a geocoded pin on the street no longer pulls the premises toward the road.
- `curtilage places` and `Curtilage.places`: pins from Overture Maps places by category, brand or place id, in a region or box, as CSV, NDJSON or GeoJSON that `generate` reads. Each place names its sources and licences.
- `candidates: N` (`--candidates N`): for ambiguous sites, up to N other premises (another building near the pin, the whole shopping centre on a shared lot, the building rectangle when confidence is low), each a full result with its own confidence and flags, most confident first.
- Your own named profiles from a JSON or YAML file (`Curtilage::Profiles.load`, `--profiles FILE --preset NAME`): sets of generation options, optionally starting from a built-in preset, checked at load.
- Corrections: `corrections:` (`--corrections FILE`, matched by id; the gem's own output, edited, works) uses your polygons instead of generating, validated and marked manual (`method_name: :manual`, data source `manual`). `Formats.read_results` reads result files back.
- `curtilage diff OLD NEW` (`Curtilage::Diff`): compares two runs site by site (IoU, area change, ok, flags gained and lost, confidence) and marks sites that changed beyond a threshold for review, exiting 1 when any need it.
- Big batches from the command line: `curtilage generate` works in chunks of 500 sites, shows progress with an ETA on a terminal (`--progress` to force it), streams NDJSON and CSV so memory stays flat, and `--resume` carries on an interrupted run from where it stopped. Without `--cache-dir`, a region a run builds is shared by every chunk.
- The public benchmark has hand-drawn references for its ten sites (traced on public-domain USGS imagery) and a committed baseline (`benchmark/baseline.json`).
- A `precision:` option sets the decimal places of output coordinates (default 7, as before).
- `curtilage doctor` checks everything the gem needs outside Ruby with a fix for each problem (DuckDB version, with a warning outside the tested 1.4 and 2.0; extensions; the cache folder), and takes `--network` (are the map-data hosts reachable) and `--json`; it exits 1 when something's missing.
- A `validation:` option raises or lowers the validation limits for generated polygons (e.g. `{ max_area_error_m2: 300_000 }` for a big-box store's lot, which could only ever get the fallback before). The limits are documented in the reference.
- CSV output has an `attribution` column, and KML credits every source in the document's description.
- A "Data licence" section in the README and the reference: what the ODbL asks of results (attribution, derivative databases, produced works), with links.
- A "Privacy" section in the README: what each data source and mode reveals, and to which host.
- A public benchmark in the repository (not the gem): `rake benchmark` scores results against hand-drawn references, overall and per category, on a pinned Overture release, and `rake benchmark:compare` diffs two runs. It ships as a skeleton with placeholder sites.

### Changed

- Lookups in local built files are about three times faster (7 ms to 2 ms a pin): one scan joined to the pins' boxes instead of a scan per pin. Files in a bucket keep a scan per pin, so only the parts near each pin are read. New builds use smaller row groups (5,000 rows), which speeds up those reads; existing builds work as before.
- Reading map features is faster (8 ms to 6.6 ms a site): checking polygons for self-intersection sweeps edges in order instead of comparing every pair, with the same answers.
- Generation is faster with identical results: road trims no longer sample road segments too far from the building to matter. About five times on ordinary buildings (34 ms to 7 ms a site on 500 made-up pins), about 1.4 times on busy commercial sites (median 92 ms to 65 ms on a held-out set).
- Results no longer depend on the order map data arrives in (DuckDB promises no row order, so a re-run could give a different polygon on about a fifth of sites). Neighbouring buildings are now cut nearest first, and the input is sorted into one order before the rules run. Some polygons change: on a private held-out set, mean IoU against hand-drawn premises went from 0.469 to 0.466 (random input orders used to give 0.464-0.466).

### Security

- Downloads refuse any host but Geofabrik, Overture's catalogue and Microsoft's footprint host.
- One pin check for every entry point: coordinates must be finite plain decimals in range. Hexadecimal (`0x1A`) and underscores (`1_0`) used to be read as numbers from pin files and `--pin`, out-of-range values from files reached the results, and `Curtilage.generate` didn't check its pin. A bad `--pin` now gives a message instead of a stack trace.
- Pin files are refused up front if they aren't valid UTF-8 or contain NUL bytes, and capped as they're read (field length, columns, rows, GeoJSON features), so an oversized file fails early with a clear message.
- Generation options are range-checked (no negative or kilometre-scale distances, whole-number vertex counts), and an Overture `release:` must look like a release name (it goes into a URL path).
- DuckDB queries have a timeout (600 s for lookups and Overture reads, `CURTILAGE_DUCKDB_TIMEOUT` or `lookup: { timeout: }`; 3600 s for builds), after which DuckDB and anything it started are stopped. Output is read as it arrives and DuckDB is stopped once it passes the cap, instead of reading 200 MB before checking. Lookups and Overture reads cap DuckDB at 1 GB of memory (`lookup: { memory_limit: }`). Error messages no longer quote the failed query, which could include the box around a pin. `doctor` shows the path of the DuckDB binary it runs.
- The preview page carries a Content-Security-Policy that allows only its own inline style and script, by hash, and no loads, so a missed escape couldn't run script; Unicode direction controls are dropped from the names it shows.
- CSV output guards more ways a spreadsheet runs a cell as a formula: a leading `|` or `%`, full-width forms, and any of them after leading whitespace, in every column.
- `--out` files are written atomically, and a symbolic link at the target is refused before any work starts.
- Fuzz tests for the CSV and GeoJSON readers, map-data parsing, geometry on degenerate input, validation, and generation near the poles and the antimeridian (`FUZZ_ITERATIONS` for longer runs). They found no crash; sites on the antimeridian get no polygon (now a known limitation).
- Zip extraction caps what the layers may inflate to (20 GB in all, 200 times per member), and a whole zip downloaded when a server can't serve ranges gets the same name and size checks before `unzip`, which now drops folder paths.
- Builds record the size and SHA256 of every file they download in the region's metadata, and warn when a rebuild finds Geofabrik's file for the same date has changed.
- The cache folder is created readable only by you, and one that another user owns or everyone can write to is refused. Builds record their Parquet file's size and SHA256; a cached file that's missing or the wrong size is rebuilt (caches built by earlier versions rebuild once), and `curtilage doctor --verify DIR` checks every file's hash.
- Interrupting a run (Ctrl-C) stops DuckDB too; it has its own process group, so before this the caller waited for the query to finish. A failed or interrupted download leaves no `.part` file, and `curtilage build` without `--work` uses a private temporary folder instead of a fixed name in `/tmp`.
- Offline mode (`CURTILAGE_OFFLINE=1`): extensions are loaded but never installed, and downloads, Overture reads and bucket reads are refused. `doctor` prints the extension versions it loads, and builds record the DuckDB and `spatial` versions. A test checks that no SQL the gem builds relaxes extension signature checks. `curtilage build` reports errors as a message instead of a stack trace.
- `generate_many` checks every pin before fetching any data (a bad pin used to fail the batch after builds had run), takes at most 100,000 pins per call (`max_pins:`), refuses unknown `data:` options, and checks `parallel_builds` (1 to 8), `max_age_days` and `auto_build_min_pins`.
- In a batch, a site whose generation raises gets a result flagged `error` (with the error in its explanation) instead of aborting every other site; generation options are checked once, before any data is fetched.
- The Docker image pins its base image by digest, checks the DuckDB download against a pinned SHA256, leaves curl and unzip out of the image that runs, and works offline and with a read-only root filesystem. CI actions are pinned to commit SHAs; CodeQL and `bundler-audit` run in CI, and CI builds the image and runs it with no network.
- Downloads honour `HTTPS_PROXY` and `NO_PROXY` without `curl` too (Ruby's client read `http_proxy` instead).
- `unzip` is no longer needed: a zip downloaded whole (when a server can't serve byte ranges) is read by the gem itself, with the same name, size and CRC checks as range downloads.
- Text placed into DuckDB SQL (paths, bucket URLs, folders) may not contain line breaks or NUL bytes, `memory_limit` must look like `"400MB"`, and `threads` must be 1 to 64. Tests push crafted values through every path into SQL.

### Fixed

- Results from catalogues and Geofabrik builds carry the build's attribution, so builds with Microsoft footprints credit Microsoft (they credited only OpenStreetMap). Overture results that can use non-OSM buildings credit each source used.
- Microsoft's Global ML Building Footprints are under CDLA Permissive 2.0, not ODbL as the docs and build metadata said.

- Text is read as UTF-8 whatever the system locale. Under `LANG=C` (common in containers and cron jobs), a map feature with a non-ASCII name (such as "Café") made lookups raise an encoding error, and so did a data catalogue whose attribution contained `©`.
- Works with DuckDB 2.0 (what Homebrew installs) as well as 1.4: it renamed the extension folder setting and deprecated `s3_region` (both warned inside the JSON output), dropped the `->` lambda syntax and reads stored geometry as bytes (1.4 reads it as a geometry; a cast suits both). Run from an AI coding tool, DuckDB 2.0's "agent mode" is turned off for the gem's own calls, since it changes the output.
- No warning on Ruby 4.0, which removed the CGI library (only `cgi/escape` is loaded now). CI tests Ruby 4.0 too.
- Small downloads (region and file indexes) stop as soon as they pass their size cap, instead of after the whole response has arrived.
- Errors are `Curtilage::Error` (or `ArgumentError` for bad input) as documented: an unreadable catalogue file, a bad Geofabrik index or zip data that won't inflate used to surface as `JSON::ParserError`, `KeyError` or `Zlib::DataError`, and a pin containing `nil` as `TypeError`.
- The cached Geofabrik index and each region's `.json` are written atomically, and a cached index that can't be read is fetched again. A copy cut short (a killed process, a full disk) used to break every run until it aged out after a month.
- When one of several parallel builds fails, the others finish (and start no new region) before the error is raised; the temporary folder used to be deleted under builds still running. Download threads do the same, and failed threads no longer print to stderr.
- `Build.run` refuses a `date:` that isn't `YYMMDD` (it goes into a file name and URL).

## [0.3.0] - 2026-11-22

### Breaking

The API may change before 1.0; these changes need callers of 0.2.0 to adjust.

- Command line: `generate` output is now always one GeoJSON FeatureCollection, each feature with `properties.id`. Several pins used to print a JSON list, and one pin with `--no-store` a single Feature.
- Generation options are checked: a misspelt or unknown option raises `ArgumentError` instead of being silently ignored.
- `method: :box` and the `box_side_m` option are gone. The box was only a baseline for testing and crossed public roads on most sites.
- Internal helpers on `Curtilage` (such as `auto_plan`, `run_many`, `generate_one`) are private. Only what `docs/reference.md` documents is public API.

### Added

- Command line: `generate --in FILE` reads pins from a CSV (`lng`, `lat`, optional `id`) or GeoJSON, and `--out FILE` / `--format` write GeoJSON, CSV or KML.
- `curtilage preview` and `Curtilage::Preview.html`: an HTML page with a map of each site, drawn from its map data, to check results by eye: premises, store zone, the site's building and its neighbours, parking, roads, railways and driveway entrances, with a scale bar, the flags (explained on hover), the details and the step-by-step explanation. `--buffer METRES` also draws the premises grown by that much. Sites can be filtered (needs a look, not valid, by flag) and sorted (needs a look first, id, premises size). It loads nothing from the internet.
- `Result#details`: the building (id, name, type, area, footprint), mapped parking inside the premises and an estimate of spaces, street frontage, and where driveways meet the street.
- `Result#buffered(metres)` grows or shrinks the premises evenly (a geofence with a margin); `Result#to_wkt` and `#store_wkt`; `to_geojson(properties:)`.
- `Result#problem`: why a result isn't usable, in words ("no premises: no building within 30 m of the pin"); also in the preview, the KML description and a CSV column. When no building is near the pin, the explanation suggests `buildings: :osm_filled` (the usual cause is a building missing from OpenStreetMap).
- `Curtilage.building_at(pin)`: just the building at a pin.
- `Curtilage::Formats`: read pins from CSV or GeoJSON, write results as GeoJSON, CSV or KML, from Ruby.
- `Curtilage::Error`: the base of every error the gem raises, so one `rescue Curtilage::Error` catches them all. A missing DuckDB or `unzip` binary now says what to install instead of raising `Errno::ENOENT`.
- `Curtilage::FLAGS`: every review flag and what it asks a person to check.
- `generate_many(keep_features: true)` keeps each result's map data (`Result#features`); `data: { log: }` sends build progress somewhere other than standard error.
- A `Dockerfile` with the gem, DuckDB and its extensions.
- `Curtilage::Result` replaces `Curtilage::Generator::Result` (still available under the old name).

### Fixed

- With `parallel_builds` above 1, a batch could hang waiting for a region that another worker had already taken.
- Reusing one `Features` for several generations with different options could carry a "shared lot" decision from an earlier run into a later one.
- When Overture reads failed during an `:auto` run, the temporary build folder could be deleted while a build was still writing to it.
- Lookups of more than about 1,000 pins at once failed (DuckDB's query depth limit); built-file and Overture reads now go in batches of 500, and the 10,000-pin limit per call is gone.
- A pin standing near the street (closer to the road centreline than half the road's width) could fall outside the premises, which then failed validation. Road trims now stay clear of the pin as well as the building, and simplifying the premises always keeps the pin.

### Changed

- Premises edges beside straight roads stay square to the building instead of cutting diagonally across the lot. Each road's direction comes from its length-weighted mean heading (snapped square to the building within 10 degrees, was 5), and the lot grows as a box aligned with the building rather than the convex hull of building and parking. On 164 held-out sites, slanted road edges fell from 15 sites to 7 and valid results rose from 158 to 159.
- `:auto` runs its Geofabrik builds and Overture reads side by side instead of one after the other.
- `:auto` builds a region from 10 pins instead of 20 (`auto_build_min_pins`), from measured timings: Overture about 5.6 s a pin, a mid-size US state about 60-90 s to build. Fewer areas go to Overture as a result.
- README: test results on held-out sites, a "Known limitations" section, and clearer usage docs.

## [0.2.0] - 2026-11-22

- New default data source `:auto`: scattered pins are read from Overture Maps (seconds, nothing downloaded) and a Geofabrik region is built only once enough pins share it (`auto_build_min_pins`, 20) or it's already cached. A batch spread over many states no longer downloads a whole state per site. `:geofabrik` stays available for when only the region may be revealed. Results say which source they used.

- Downloads retry network hiccups (timeouts, dropped connections, server errors; 3 tries with backoff) instead of failing the build.
- Downloads use the `curl` command when it's installed, which streams several times faster than Ruby's HTTP client (`CURTILAGE_CURL=0` turns it off).
- On-demand builds can run several regions at once: `data: { parallel_builds: 2 }` (default 1, for 1 GB machines). Each build gets its own work folder.
- Builds record their region's outline (from Geofabrik's index), and a `Catalogue` uses it instead of the bounding box to decide which files cover a pin. A pin whose surroundings run into a region that isn't built is flagged `partial_data` instead of silently missing buildings.

## [0.1.0] - 2026-11-21

First release. What it does:

### Premises
- Grows the building's rectangle 30 m toward its lot, trims at public roads and railways, and claims the site's parking; falls back to the building rectangle plus a margin when that fails validation. Every result has a step-by-step explanation.
- Roads: stops half a typical road width short of the centreline (by road class), but always at least 3 m out from the building (`building_clearance_m`). Cuts follow each road's fitted direction beside the site, nearest road first, snapped square to the building within 5 degrees. Roads and railways in tunnels or on bridges are ignored.
- Railways at ground level bound the premises like roads.
- Neighbours: stops 3 m short of a neighbouring building, square to the building (halfway when the gap is narrower). Homes (typed in OSM, or untyped small buildings in a row) get the halfway split when the site is behind them (their back yard, judged by which way they face their street).
- Lot: mapped parking within 20 m of the building is the site's, up to the kerb and at most 60 m out. A lot shared with one or two other buildings is claimed whole (split halfway only with homes); a shopping-centre lot (three or more buildings) is split by nearest building. Parking garages, carports and canopies next to the building count as lot, and driveways linking the lot to a public road are taken in up to the kerb.
- When the pin isn't on a building, the nearest real building within 30 m is used, not a tiny canopy next to it.
- Presets: `:whole_lot` (default), `:tight` (building plus a small margin) and `:centre` (a store on a shared lot gets the whole shopping centre, flagged `shopping_centre`).

### Store zone
- `result.store_ring` is the building's OSM outline (any shape, at most 20 corners, never self-crossing), always inside the premises: the premises take in the whole building and the outline is clipped 5 cm inside them. `store_zone: false` turns it off.

### Flags and validation
- Flags, checked against reviewed sites: `near_houses`, `large_building` (over 5,000 m2), `small_building` (under 50 m2), `building_not_under_pin`, `store_may_be_unit` (over 1,500 m2), `shopping_centre`, `fallback`, `ml_footprint`, `no_data`.
- `Validation.check` errors on missing, unclosed, self-intersecting or swapped rings, a pin outside, vertices too far away, too many vertices, or an area over 100,000 m2; warns on small, large or off-centre polygons.
- `Audit.check` scores an existing polygon (crosses a road, covers a neighbour, differs from what would be generated).

### Data
- On demand: `generate_many(pins)` finds each pin's region in Geofabrik's index (worldwide), builds only those regions into a temporary folder or `cache_dir:` (reused for a month, locked so concurrent jobs build once) and cleans up.
- `source: :overture`: reads features in place from Overture Maps' latest release, using its file index and sharing reads between nearby pins; a silent network stall is retried once.
- `curtilage build REGION`: any US state or Geofabrik region path; downloads only the layers it uses with HTTP range requests (CRC-checked, full-file fallback), reads every part of split layers and multi-part regions (California), keeps building types, and builds with DuckDB capped at 400 MB and 1 thread. Writes `<region>.json` metadata beside the Parquet file.
- `Catalogue`, batch lookups (`Lookup.features_many`), Parquet read from `s3://`, `gs://` or `https://`.
- Optional machine-learned building footprints (Microsoft, ODbL): `--ml-footprints microsoft`, then `buildings: :osm_filled` or `:ml`. OSM only is the default.
- Map data is treated as untrusted: size and vertex caps, invalid geometry dropped and counted.

### Interface
- `Curtilage.premises(pin)` for one pin with no setup; `Curtilage.generate_many`, `Curtilage.generate`, `Result#to_geojson` (with attribution; `include_store: true` for both shapes).
- `Curtilage.configure` (or `CURTILAGE_*` environment variables) for the DuckDB path, cache folder and data source; DuckDB's extensions install themselves.
- Commands: `curtilage generate` (works with only `--pin`), `curtilage build`, `curtilage doctor`.
- `docs/reference.md` documents every option, setting, flag and command.
- MIT licence.
