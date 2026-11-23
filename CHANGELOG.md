# Changelog

## [Unreleased]

### Added

- CSV output has an `attribution` column, and KML credits every source in the document's description.
- A "Data licence" section in the README and the reference: what the ODbL asks of results (attribution, derivative databases, produced works), with links.
- A "Privacy" section in the README: what each data source and mode reveals, and to which host.
- A public benchmark in the repository (not the gem): `rake benchmark` scores results against hand-drawn references, overall and per category, on a pinned Overture release, and `rake benchmark:compare` diffs two runs. It ships as a skeleton with placeholder sites.

### Security

- Downloads refuse any host but Geofabrik, Overture's catalogue and Microsoft's footprint host.
- One pin check for every entry point: coordinates must be finite plain decimals in range. Hexadecimal (`0x1A`) and underscores (`1_0`) used to be read as numbers from pin files and `--pin`, out-of-range values from files reached the results, and `Curtilage.generate` didn't check its pin. A bad `--pin` now gives a message instead of a stack trace.
- Pin files are refused up front if they aren't valid UTF-8 or contain NUL bytes, and capped as they're read (field length, columns, rows, GeoJSON features), so an oversized file fails early with a clear message.
- Generation options are range-checked (no negative or kilometre-scale distances, whole-number vertex counts), and an Overture `release:` must look like a release name (it goes into a URL path).
- DuckDB queries have a timeout (600 s for lookups and Overture reads, `CURTILAGE_DUCKDB_TIMEOUT` or `lookup: { timeout: }`; 3600 s for builds), after which DuckDB and anything it started are stopped. Output is read as it arrives and DuckDB is stopped once it passes the cap, instead of reading 200 MB before checking. Lookups and Overture reads cap DuckDB at 1 GB of memory (`lookup: { memory_limit: }`). Error messages no longer quote the failed query, which could include the box around a pin. `doctor` shows the path of the DuckDB binary it runs.
- The preview page carries a Content-Security-Policy that allows only its own inline style and script, by hash, and no loads, so a missed escape couldn't run script; Unicode direction controls are dropped from the names it shows.
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
