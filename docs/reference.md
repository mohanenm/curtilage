# Reference

Everything curtilage offers, in one place. For an overview, see the [README](../README.md). This is the public API: anything not listed here is internal and may change without notice.

## Ruby API

### `Curtilage.premises(pin, **options) → Result`

The simplest call: premises for one `[lng, lat]` pin, fetching map data as configured. Takes the same options as `generate_many`.

### `Curtilage.building_at(pin, **options) → Hash or nil`

Just the building at a pin (the one its premises would be made from): `{ id:, name:, type:, area_m2:, footprint: }`, with `footprint` a closed `[[lng, lat], ...]` ring. `nil` if there is none. Same options as `premises`.

### `Curtilage.generate_many(pins, **options) → [Result]`

Premises for many pins, in pin order. Pins that share map data share the work. Every pin is checked before any data is fetched (a bad one raises `ArgumentError` naming it), and so are the generation options; a call takes at most 100,000 pins (`max_pins:` raises the cap; bigger batches are better split). If generating one site raises, that site gets a result with the `error` flag and the error in its explanation, and the rest of the batch goes on; problems fetching map data still raise for the whole call.

| Option | Default | What |
|---|---|---|
| `source:` | `Curtilage.config.source` (`:auto`) | `:auto`: build a Geofabrik region when enough pins share it (`data: { auto_build_min_pins: 10 }`) or it's already cached, and read scattered pins from Overture Maps. `:geofabrik`: always build the pins' regions (the host learns only the region; use this for sensitive location lists). `:overture`: always read Overture Maps in place (its storage host learns roughly where each pin is). See the README's [Privacy](../README.md#privacy) section. |
| `cache_dir:` | `Curtilage.config.cache_dir` (none) | Keep on-demand builds here and reuse them for a month. Without it, builds go to a temporary folder deleted afterwards. A new folder is created readable only by you; one another user owns, or that everyone can write to, is refused. A cached file that's missing or the wrong size is rebuilt. |
| `catalogue:` | none | A `Curtilage::Catalogue` of regions built ahead of time (overrides `source:`). |
| `parquet:` | none | One built file, or a list, local or `s3://`, `gs://`, `https://` (overrides `source:`). |
| `lookup:` | `{}` | `duckdb:`, `extension_directory:` (default: the configuration), `setup_sql:` (e.g. `CREATE SECRET` for a private bucket), `radius_deg:` (how far around each pin to read, default 0.004), `memory_limit:` (DuckDB's memory cap for lookups and Overture reads, default `"1GB"`), `timeout:` (seconds before a DuckDB query is stopped, default `Curtilage.config.duckdb_timeout`, 600). |
| `data:` | `{}` | For builds: `max_age_days:` (31), `ml_footprints:` (`"microsoft"`), `parallel_builds:` (1, at most 8; each build peaks near 600 MB, so raise it to 2-3 only on machines with the memory). An unknown `data:` option raises `ArgumentError`. For `:auto`: `auto_build_min_pins:` (10). For Overture: `release:` (default: the latest; a release name such as `"2026-11-18.0"`). `log:` where build progress goes (anything with `puts`; default standard error). |
| `preset:` | none | `:whole_lot`, `:tight` or `:centre` (below). |
| `method:` | none | `:grow_trim` or `:building` to force one method, no fallback. |
| `parcels:` | `nil` | Property lines you supply: a GeoJSON file of Polygons or MultiPolygons, or GeoParquet (a WKB `geometry` column) as a local path or a URL DuckDB can read (`lookup: { setup_sql: }` for a private bucket). Only parcels near the pins are used ([Parcels](#parcels)). |
| `corrections:` | `{}` | `{ pin index => ring }` (or `{ ring:, store_ring: }`), 0-based: use these polygons instead of generating ([Corrections](#corrections-and-comparing-runs)). Their pins fetch no data. |
| `candidates:` | none | 1 to 5: also return other premises for ambiguous sites ([Candidates](#candidates)). |
| `keep_features:` | `false` | Keep each result's map data in `Result#features` (needed by `Preview` to draw the surroundings). Off by default to save memory on big batches. |
| any generation option | | See the table below. |

### `Curtilage.places(region: or bbox:, category: or brand: or ids:, **options) → [Hash]`

Pins from [Overture Maps places](https://docs.overturemaps.org/guides/places/), for when you have no pin list. One filter: `category:` matches any level of Overture's taxonomy (`"pharmacy"`, or `"health_care"` for everything under it) or its basic category; `brand:` the brand's primary name, any case; `ids:` a list of Overture place ids. Where: `region:` (a US state such as `"virginia"`, or a Geofabrik path, matched to its outline from Geofabrik's region index) or `bbox:` `[west, south, east, north]` (at most 400 square degrees). `min_confidence:` (0 to 1) drops places Overture is less sure of; `release:` picks an Overture release; DuckDB options as elsewhere. Places that are permanently or temporarily closed are left out.

Each place is `{ id:, name:, brand:, category:, confidence:, sources:, licences:, pin: [lng, lat] }`, sorted by id, at most 100,000. Places carry their own licences by source (most CDLA Permissive 2.0, AllThePlaces CC0, Foursquare Apache 2.0, which asks for its licence and notice to be kept); they're inputs, and premises made from them are ODbL like any other. Reading them tells Overture's storage host which box was read, and a `region:` downloads Geofabrik's region index.

```ruby
places = Curtilage.places(region: "delaware", category: "pharmacy", min_confidence: 0.9)
results = Curtilage.generate_many(places.map { |p| p[:pin] })
```

### `Curtilage.point_in_premises?(ring, point) → true or false`

Whether a `[lng, lat]` point (a device's location) is inside a premises ring as you stored it (`[[lng, lat], ...]`, closed or not); on the edge counts as inside. Plain Ruby, no database needed. For PostGIS, see [the PostGIS recipe](recipes/postgis.md).

### `Curtilage::H3.cover(results, resolution, **lookup) → results`

Sets `result.h3 = { resolution:, cells: [...] }` on each result with premises: the H3 cells (resolution 0-15) the premises touch, so even a small site gets at least one. Also `--h3 RES` on the command line; the cells appear in GeoJSON/NDJSON (`properties.h3`), CSV (`h3_cells`, `;`-separated) and the GIS formats. It uses DuckDB's **community** `h3` extension, installed on first use from DuckDB's community repository (built and signed by DuckDB from third-party code); with `CURTILAGE_OFFLINE=1` it must be installed already. The extension isn't published for every DuckDB release (at the time of writing: 1.4 LTS yes, 2.0.1 no); where it's missing, a `DependencyError` says so.

### `Curtilage.generate(pin, features, **options) → Result`

Premises from features you already have (from `Curtilage::Lookup.features` or `Curtilage::Overture.features_many`), with the same `preset:`, `method:` and generation options.

### `Result`

| Field | What |
|---|---|
| `ok?` | The premises passed validation. Never save one that isn't. |
| `problem` | Why they aren't usable, in words (e.g. `"no premises: no building within 30 m of the pin (it may be missing from OpenStreetMap: try buildings: :osm_or_ml)"`), or `nil` when `ok?`. |
| `ring` | The premises: `[[lng, lat], ...]`, closed, convex, at most `max_vertices` corners. `nil` if nothing could be made. |
| `store_ring` | The store zone: the building's own outline, always inside `ring`. `nil` with `store_zone: false`. |
| `candidates` | With `candidates: N`, up to N other premises the site could have, most confident first, each a full `Result` ([Candidates](#candidates)); `nil` otherwise. |
| `approach_ring`, `pickup_ring` | The [zones](#zones), when asked for (`approach_m:`, `pickup_m:`); `nil` otherwise. |
| `staging_point` | `[lng, lat]` where a driver might wait, estimated, with a pickup zone ([Zones](#zones)); `nil` otherwise. |
| `entrances` | Where vehicles enter from the street, with the street's name and class (`details[:entrances]`, below); `[]` when none. |
| `flags` | Reasons a person should look first (below). |
| `pin_quality` | `{ quality:, building_m:, moved_from: }`: where the pin was given (`on_building`; `on_road`, within half a public road's width of its centreline; `near_building`, a building within `building_max_distance_m`; or `far`), the distance to the nearest building's edge (0 on one, absent with none), and with `snap_m:` the pin as given when it was moved (`pin` is then the moved pin). `nil` for results that raised an error. |
| `explanation` | Each step, in plain words. |
| `steps` | The same steps as records, one per line of `explanation` and in the same order, for tools to show or audit (below). |
| `validation` | `errors`, `warnings` and `metrics` (area, rectangularity, pin inside, distances). |
| `method_name` | `:grow_trim`, or `:building` after a fallback; `:manual` for a [correction](#corrections-and-comparing-runs). |
| `building` | The id of the building used. |
| `attribution` | What to credit wherever the result is shown: OpenStreetMap, plus Overture, Overture's non-OSM building sources or Microsoft's footprints when the result could use them. `nil` means OpenStreetMap only (`Result::OSM_ATTRIBUTION`). |
| `pin` | The pin it was made for. |
| `details` | Facts about the site, rough by nature (open map data); `nil` when no premises were made. See below. |
| `confidence` | How far to trust the result, 0 to 1 (below). `0.0` when not `ok?`. |
| `confidence_factors` | The factors behind it: `[{ name:, met:, weight: }, ...]`, every factor listed. |
| `provenance` | What the result was made from, to reproduce or audit it (below). |
| `features` | The map data it was made from (`Curtilage::Features`, in metres around the pin), or `nil` unless `keep_features: true`. |
| `to_geojson(include_store: false, properties: {})` | A GeoJSON Feature (premises) with everything above in its properties, including the attribution to show; with `include_store: true`, a FeatureCollection of premises and store zone (`properties.role`). `properties:` are merged into each feature's properties (your own id, say). |
| `to_wkt`, `store_wkt`, `approach_wkt`, `pickup_wkt`, `staging_wkt` | The premises and store zone as well-known text (`POLYGON ((lng lat, ...))`), for databases and spreadsheets. |
| `enclosing_circle`, `fit_circle` | Circles for geofences that take only circles (Android's Geofencing API, iOS's `CLCircularRegion`): `{ centre: [lng, lat], radius_m: }`. `enclosing_circle` is the smallest circle holding the whole premises (radius rounded up); `fit_circle` has the premises' area, centred on them. `nil` without premises. Also in GeoJSON properties and CSV columns. |
| `simplified(max)` | The premises with at most `max` corners (3 or more) for platforms with a vertex limit, dropping corners only while the pin and store zone stay inside and the outline stays simple: it may keep more when that can't be done. `nil` without premises. |
| `buffered(metres)` | The premises grown (positive) or shrunk (negative) evenly, as a closed ring: a geofence with a margin. Corners are rounded when growing. `nil` if there are no premises or they shrink away. Non-convex premises (`entrances: :all`) are buffered on a half-metre to two-metre grid, keeping the part round the pin. |

`provenance`:

| Key | What |
|---|---|
| `gem_version` | The curtilage version that made it. |
| `data` | `{ source: "overture", release: "2026-11-18.0" }`; `{ source: "geofabrik", regions: [{ region:, extract_dates: [...], ml_footprints: { source:, fetched: } }] }` for builds and catalogues (`ml_footprints` only when the build added them; their source publishes no dates, so `fetched` is the build's date); `{ source: "parquet" }` for a lone `parquet:` file; `nil` when no data covered the pin or features were passed to `generate` directly. |
| `features_sha256` | A SHA256 of the map data the result was made from, the same whatever order the features came in. Two results with the same hash, version and options used the same inputs. |
| `options` | Every generation option after defaults and presets. |

It holds no timestamps: the same pins, options and data give the same output, byte for byte, whatever order the map data arrives in. Results that failed with an error carry only `gem_version`.

`details`:

| Key | What |
|---|---|
| `building` | `{ id:, name:, type:, area_m2:, footprint: }`: the building used (`type` is OSM's `building=*` value). |
| `parking_area_m2` | Mapped parking inside the premises. |
| `parking_spaces_estimate` | That area over 25 m2 a space (aisles included). Unmapped parking counts as none. |
| `frontage_m` | Length of premises edges running along a public road. |
| `access_points` | `[[lng, lat], ...]`: where driveways taken into the premises meet the street (entrances within 10 m are counted once). |
| `entrances` | The same entrances with what they open onto: `[{ point: [lng, lat], street:, street_class:, street_id:, driveway: }, ...]` (`street` is the street's name, `nil` when unnamed; `driveway` the driveway's id). Also `Result#entrances`. |

### Errors

Every error the gem raises on purpose is a `Curtilage::Error` (or a subclass: `Lookup::Error`, `Overture::Error`, `Build::Error`, `Download::Error`, `Footprints::Error`, `ZipRange::Unsupported`, `ZipRange::Corrupt`), so `rescue Curtilage::Error` catches them all. Mistakes in what you pass (a bad pin, option or file) raise `ArgumentError`. A missing DuckDB binary, or extensions that won't load, is a `Curtilage::DependencyError` (a `Curtilage::Error`) saying what to install.

### Presets

| Preset | What |
|---|---|
| `:whole_lot` | The default: the building and its whole customer-facing lot. |
| `:tight` | The building plus an 8 m margin, still trimmed at roads. |
| `:centre` | Like `:whole_lot`, but a store on a shared shopping-centre lot gets the whole centre (flag `shopping_centre`). |

Any option passed with a preset overrides it.

**Your own profiles.** `Curtilage::Profiles.load(path)` reads named sets of generation options from a JSON (`.json`) or YAML (`.yml`, `.yaml`) file and returns `{ name => options }` to pass to `generate` or `generate_many`. A profile may start from a built-in `preset:`; names (`method`, `scope`, `buildings`, `preset`) are written as text. Every profile is checked like options passed directly, so a mistake fails at load, naming the profile. Files are capped at 1 MB and 100 profiles; YAML is read safely (no aliases or objects).

```yaml
big_box:
  preset: whole_lot
  parking_max_extent_m: 150
  validation: { max_area_error_m2: 300000 }
```

```ruby
options = Curtilage::Profiles.load("profiles.yml")[:big_box]
Curtilage.generate_many(pins, **options)
```

On the command line: `--profiles FILE --preset big_box`; other flags given with it override the profile.

### Generation options

All distances in metres, areas in square metres. These are `Curtilage::Generator::DEFAULTS`. An unknown or misspelt option raises `ArgumentError`, and so does a value out of range: distances must be 0 to 1,000 m, areas 0 to 10,000,000 m2, `max_vertices` a whole number from 4 to 50, `max_store_vertices` from 3 to 200, `shared_lot_buildings` from 1 to 1,000, `precision` a whole number from 5 to 15 (`Generator::RANGES`).

| Option | Default | What |
|---|---|---|
| `store_zone` | `true` | Also return the building's outline as the store zone. |
| `buildings` | `:osm` (`:osm_or_ml` for Overture reads) | Sites read from Overture (`source: :overture`, and `:auto`'s scattered pins) default to `:osm_or_ml`, since Overture's non-OSM buildings come with the data; pass `buildings: :osm` to turn that off. Choices: `:osm`, `:osm_or_ml` (OSM alone unless no OSM building is under the pin or within `building_max_distance_m`; then as `:osm_filled`, so only sites missing from OSM change), `:osm_filled` (machine-learned footprints added wherever they don't overlap an OSM building) or `:ml`. The footprints have to be in the data: a build with `--ml-footprints microsoft`, or Overture's non-OSM buildings. |
| `scope` | `:site` | `:site`, or `:centre` for the whole shopping centre (for arrival detection: anywhere in the centre is on site). A centre is a mapped lot shared with three or more businesses, or, where OSM maps a centre's lot only as aisles, the service roads joined to the site's (within 150 m, not alleys behind homes) when three or more businesses front them; it's outlined round those strips and buildings. Homes are never part of a centre. A centre over `centre_max_m2` keeps the site's own share (flag `large_centre`). |
| `grow_m` | `30` | How far the building's rectangle grows toward its lot before trimming. |
| `road_offset_m` | `nil` | How far short of road centrelines to stop; `nil` uses half a typical road width by class: motorway 12 m, trunk 8.5, primary 7.5, secondary 7, tertiary 6, unclassified 5, residential 4.5, links 5. |
| `building_clearance_m` | `3` | Road trims stop at least this far from the building. |
| `neighbour_gap_m` | `3` | Strip left to a neighbouring building; `nil` splits halfway. |
| `neighbour_min_area_m2` | `40` | Smaller buildings (sheds) don't bound the lot. |
| `neighbour_strip_min_area_m2` | `0` | Neighbours smaller than this are split halfway instead of getting the strip. |
| `house_max_m2` | `250` | An untyped building smaller than this, among other small ones, counts as a home. |
| `house_street_m` | `25` | ... when two more small buildings are this close. |
| `parking_reach_m` | `20` | Mapped parking this close to the building is its lot. |
| `aisle_m` | `9` | Treat this much either side of each service road near the building (within `parking_reach_m` plus this) as parking, for lots OpenStreetMap maps only as aisles and driveways. The strips are claimed, shared, trimmed and fenced like mapped parking. 9 m is half an aisle plus a stall. `nil` turns it off. |
| `parcel_mode` | `:clip` | With parcels: `:clip` clips to the building's parcel; `:grow` adds the paving inside the site's parcels, without clipping; `:start` begins from the site's parcels and trims them with the usual rules. Experimental ([Parcels](#parcels)). |
| `neighbour_cut` | `:line` | How the premises keep off neighbouring buildings after the lot is taken in: `:line` cuts straight across, square to the building; `:notch` (experimental) cuts round each neighbour 1 m clear, so a lot running past a neighbour keeps the part beyond it. Neighbours the premises surround still get a line cut. |
| `centre_max_m2` | `50000` | With `scope: :centre`, a centre bigger than this (a regional mall) isn't used: the site keeps its own share of the lot (flag `large_centre`), as "anywhere in the mall" is too coarse to mean at the store. |
| `lot_share_reach_m` | `5` | Another building this close to the site's lot (across a walkway) shares it: with `shared_lot_buildings` or more such buildings the lot is split between them. Buildings farther off, across an aisle or behind, don't count. The site itself takes a share of such a shared lot only when it's this close too; a shared lot across an aisle or planting strip belongs to the others. |
| `parking_max_extent_m` | `60` | Parking is claimed at most this far from the building. |
| `shared_lot_buildings` | `3` | A lot touching this many other buildings is a shopping-centre lot. |
| `building_max_distance_m` | `30` | When the pin isn't on a building, use the nearest one only this close. |
| `pin_clearance_m` | `5` | Room kept around the pin. |
| `small_building_m2` | `50` | Flag `small_building` below this; such structures count as lot next to a real building. |
| `large_building_m2` | `5000` | Flag `large_building` above this. |
| `large_building_note_m2` | `1500` | Above this, explained (and the store zone flagged `store_may_be_unit`). |
| `building_margin_m` | `20` | The fallback's margin around the building rectangle. |
| `max_vertices` | `10` | The premises are simplified to at most this many corners (never cutting the building). |
| `max_store_vertices` | `20` | The store outline is simplified to at most this many corners. |
| `validation` | `{}` | Limits for the validation every polygon goes through (below), e.g. `{ max_area_error_m2: 300_000 }` for a big-box store's lot. |
| `snap_m` | `nil` | Move a pin that isn't on any building 1 m inside the nearest one within this distance (real buildings before kiosks), then generate from there. Flags `pin_moved`; `pin_quality` keeps where it was given. Useful for geocoded pins that land on the street, which otherwise pull the premises toward the road (they always hold the pin). |
| `approach_m` | `nil` | Also make an approach zone: the premises grown by this much, for "customer is near" (see [Zones](#zones)). `Generator::DEFAULT_APPROACH_M` is 150. |
| `entrances` | `:near` | `:near` takes in a driveway only where it leaves the lot close by. `:all` follows the mapped service roads from the lot to every place they meet a public road (up to 250 m along them, and at most 30 m alongside a street, so a frontage road isn't followed down the block) and adds a corridor 8 m wide along each, up to the kerb, kept off public roads, railways and neighbouring buildings. The premises are then usually **not convex**: a lot with corridors. They're simplified to `max_vertices` plus four corners per entrance (at most 50); if that can't be done they fall back to the convex outline, with a step saying so. Slower (about 0.3 s a site against 0.06 s). Experimental: off by default while it's judged on the benchmark. |
| `lot_split` | `:square` | How a shared (shopping-centre) lot is split between its buildings. `:square` cuts it halfway to each building, square to the site's building. `:voronoi` keeps the part nearer the site's walls than any other building's on the lot, then squares that up as usual. Experimental: on the public benchmark and a private held-out set it takes in a little more of the site's own and nearby shared parking with nothing more of the neighbours'; about 30 ms slower a site. |
| `unit_m` | `nil` | For a building large enough to be shared (over `large_building_note_m2`), make the store zone the slice this many metres wide along its frontage (the side facing the nearest public road, else its long side) centred on the pin, within the building. No data source maps units, entrances or address points, so it's an estimate: flag `unit_estimated` instead of `store_may_be_unit`. Buildings under 1.5 units wide are left whole. Typical units are 6-20 m wide. |
| `pickup_m` | `nil` | Also make an estimated pickup zone: mapped parking within this much of the building ([Zones](#zones)). `Generator::DEFAULT_PICKUP_M` is 25. |
| `precision` | `7` | Decimal places in output coordinates (7 is about 1 cm). Validation checks the rounded polygon. |

#### Validation limits

`Curtilage::Validation::DEFAULTS`, changed with the `validation:` option (or passed to `Validation.check`). Values must be positive numbers; an unknown limit raises `ArgumentError`.

| Limit | Default | What |
|---|---|---|
| `min_area_m2` | `1000` | Warn (`small`) below this area. |
| `max_area_m2` | `40000` | Warn (`large`) above this area. |
| `max_area_error_m2` | `100000` | Error (`too_large`) above this area: a block, not one site's lot. |
| `max_vertex_distance_m` | `1000` | Error (`too_far_from_pin`) if any corner is further than this from the pin. |
| `max_vertices` | `50` | Error (`too_many_vertices`) above this many corners. |
| `off_centre_m` | `200` | Warn (`off_centre`) if the polygon's centre is further than this from the pin. |
| `swap_far_m`, `swap_near_m` | `10000`, `1000` | Error (`swapped`) when the polygon is further than `swap_far_m` from the pin but within `swap_near_m` of it with longitude and latitude swapped. |

### Corrections and comparing runs

To fix the few bad sites once and trust the rest:

- **Corrections.** `generate_many(pins, corrections: { 3 => ring })`, or `Curtilage::Corrections.result(pin, ring, store_ring: nil)` for one site, returns the polygon you give instead of generating it: `method_name` `:manual`, `provenance` `{ gem_version:, data: { source: "manual" } }`, a `manual` step, validated like any polygon (with the `validation:` limits passed), so an invalid one is returned not `ok?`, saying why. A store zone that isn't a valid ring inside the premises is dropped, with a step. A valid correction has confidence 1.0 (the factors are just `valid`). On the command line, `--corrections FILE` (GeoJSON or NDJSON) matches polygons to sites by id; this gem's own output, edited in a GIS, works as is.
- **Comparing runs.** `curtilage diff OLD NEW` (or `Curtilage::Diff.compare(old, new, threshold: 0.9)` on two `Formats.read_results`) compares two result files site by site: `status` (`same`, `changed`, `added`, `removed`), IoU of the premises, both areas and the change in percent, `ok` before and after, flags gained and lost, and confidence before and after. A site needs `review` when it was added or removed, gained or lost premises, changed `ok`, gained a flag, or its premises overlap the old ones less than the threshold. It prints CSV (or `--format ndjson`, or `--out FILE`), says how many need review on standard error, and exits 1 when any do.
- **Keeping results stable.** The same pins, options and data give byte-identical results (see `provenance`), so a rerun only changes sites whose map data changed; re-applying your corrections keeps your fixes, and `diff` against the last run lists the sites worth a look.

`Formats.read_results(path)` reads a GeoJSON or NDJSON result file back as `{ id => { ring:, store_ring:, properties: } }` (premises and store zone; other zones skipped; rings of up to 1,000 vertices; files up to 50 MB).

### Parcels

Property lines are an extra boundary when you have them. Curtilage never fetches any: you supply them, and **their licence is yours to check** (many county parcel layers restrict reuse).

- `generate_many(pins, parcels: "parcels.geojson")` (or GeoParquet, local or a URL) reads the parcels near the pins once and adds them to each pin's map data as `"parcel"` features. With `Curtilage.generate(pin, features)`, add them yourself: `{ "feature" => "parcel", "id" => ..., "geometry" => polygon }`.
- The parcel holding at least half the building is the site's. The premises are clipped to it (to within a cell of 0.5-1 m), keeping the building and pin. Where the site's own mapped parking runs at least 100 m2 past the parcel, that parking stays in and the result is flagged `beyond_parcel`.
- A parcel that doesn't hold the building changes nothing. The premises can then be non-convex.
- `parcel_mode:` (experimental, `--parcel-mode`) says how else the parcels are used. `:clip` (the default) only clips, as above. `:grow` instead adds the mapped parking and service roads (3 m either side) inside the site's parcels, across gaps under 6 m, to the premises, and doesn't clip them. `:start` begins from the site's parcels (their outline with the building) instead of the grown building rectangle, and the usual rules trim it at roads, railways and neighbours; the parcels then set how far the lot reaches, in place of `parking_max_extent_m`. For both, the site's parcels are every parcel holding a quarter of the building (a building on several parcels) and, touching those, any parcel at least 30% covered by the site's own parking (a lot split over parcels); mapped parking mostly inside them counts as the site's. A parcel that also holds two or more other businesses' buildings (a centre) is only a limit: `:grow` and `:start` then clip as `:clip` does, flagged `shared_parcel`. `:start` falls back to the grown rectangle when the parcels' outline is over `centre_max_m2`.
- Input caps as for map data: 100 MB for a GeoJSON file, at most 5,000 corners a polygon, invalid shapes dropped.

### Candidates

When a site is ambiguous, `candidates: N` (1 to 5, on `generate`, `generate_many` or `premises`; `--candidates N` on the command line) also returns up to N other premises in `Result#candidates`, for a reviewer or a downstream system to choose from. The main result is unchanged. Alternatives come from:

- **another building** within `building_max_distance_m` of the pin (not a kiosk), in case the pin is on the wrong one: generated as if the pin were on it, flagged `pin_moved`, with `pin_quality.moved_from` the pin as given;
- **the whole shopping centre** (`scope: :centre`) when the site's lot is shared;
- **the building rectangle** (`method: :building`) when confidence is below 0.7 (`Candidates::LOW_CONFIDENCE`).

Only valid ones that differ from the main result and from each other are kept, most confident first. Each starts with a `candidate` step saying what it is. Each candidate is a full generation, so a call takes a few times longer. In GeoJSON each is a feature with `role` `candidate` and `rank`; in NDJSON, `properties.candidates` (rank, geometry, confidence, flags, building, method, explanation); in CSV, the `candidates` column counts them; in KML, placemarks; the preview draws them dashed.

### Zones

For arrival detection, two optional zones nest with the premises and store zone: approach ⊇ premises ⊇ store zone and pickup zone. Every zone is checked as a shape (closed, valid coordinates, not crossing itself) and dropped with a step if it fails; only the premises get the size limits.

- **Approach** (`approach_m:`): the premises grown by that many metres with rounded corners, then simplified to at most 16 corners by dropping only corners that keep every premises corner inside. "The customer is near." It may cross roads; the premises never do.
- **Pickup** (`pickup_m:`): the largest piece of mapped parking within that many metres of the building's rectangle, kept inside the premises. Neither OpenStreetMap extracts (Geofabrik's free shapefiles) nor Overture carry pickup or curbside spots or entrances, so it's always estimated (`estimated: true` on its GeoJSON feature): the parking right by the store, not marked bays. `nil` (with a step saying so) when no mapped parking is that close.
- **Staging point** (with a pickup zone): the pickup zone's point nearest the building, where a driver might wait. Estimated like the zone.

Building entrances (`entrance=*`) and drive-through lanes (`service=drive-through`) aren't in either data source today (Geofabrik's free shapefiles drop those tags; Overture has no entrances and no drive-through subclass), so they aren't output. Driveway entrances from the street are (`details[:entrances]`).

In GeoJSON they're extra features with `properties.role` `approach`, `pickup` and `staging` (a Point); in NDJSON, geometries in `properties.approach`, `properties.pickup` and `properties.staging`; in CSV, `approach_wkt`, `pickup_wkt` and `staging_wkt`; in KML, placemarks; the preview draws them.

### Steps

`Result#steps` (GeoJSON and NDJSON `steps`) is the explanation as records: `{ step:, text:, rule:, features:, distance_m:, area_before_m2:, area_after_m2:, flag: }`. `step` and `text` (the line of `explanation`) are always there; the rest only when they apply. `rule` names the option (from [Generation options](#generation-options)) or rule that set the distance, `features` are the map-data ids involved, and the areas are the premises in whole square metres before and after the step changed them.

| `step` | What happened | `rule` |
|---|---|---|
| `data` | Where the map data came from, or that it's missing or partial (`flag`). | |
| `fallback` | A method failed validation; the next was tried. | the method that failed |
| `error` | Generation raised an error (flag `error`). | |
| `drop_features` | Unusable map features were dropped. | |
| `find_building` | The building under the pin, the nearest one in reach, or none. | `building_max_distance_m` when not under the pin |
| `check_building`, `check_store` | The building's size or source raised a flag or a note. | `small_building_m2`, `large_building_m2`, `large_building_note_m2` |
| `grow` | The building's rectangle grown toward its lot. | `grow_m`, or `building_margin_m` (fallback) |
| `trim_road` | Trimmed at a public road or railway (one step per road). | `road_class_half_width`, `road_offset_m`, or `clearance` when the building or pin clearance kept the cut closer to the centreline |
| `keep_road_side` | A road wasn't trimmed at because the cut would cross the building. | |
| `claim_lot` | Parking, a garage or a canopy is the site's lot. | `parking_reach_m`, or `shared_lot_buildings` for a shared lot |
| `share_lot` | A claimed lot also touches other buildings. | |
| `split_neighbour` | Cut short of, or halfway to, a neighbouring building. | `neighbour_gap_m` or `halfway` |
| `keep_neighbour` | A neighbour touching the building couldn't be split off. | |
| `keep_off_lot` | Stopped at the edge of mapped parking that isn't the site's (another business's lot). | |
| `take_driveway` | A driveway to the street was taken in. | `ENTRANCE_REACH_M` |
| `add_lot` | The claimed lot was added to the premises. | `parking_max_extent_m` |
| `keep_off_neighbour` | Kept 1 m off a neighbour the lot reached. | |
| `whole_centre` | The whole shopping centre (`scope: :centre`). | |
| `widen`, `simplify` | The premises widened to hold the building, or simplified. | `max_vertices` for `simplify` |
| `trim_store` | The store outline trimmed to fit inside the premises. | |
| `approach_zone` | The approach zone made (or dropped). | `approach_m` |
| `pickup_zone` | The pickup zone estimated from a parking lot, or none found. | `pickup_m` |
| `staging_point` | The staging point placed. | |
| `candidate` | What a candidate is (first step of each `Result#candidates`). | `scope` or `method` for those alternatives |
| `manual` | The polygon is a correction, not generated. | |
| `snap_pin` | The pin moved onto the nearest building (flag `pin_moved`). | `snap_m` |
| `take_entrance` | Corridors along driveways to further entrances were added. | `entrances` |
| `estimate_unit` | The store zone estimated as one unit of a large building (flag `unit_estimated`). | `unit_m` |
| `clip_parcel` | The premises clipped to the building's parcel (or kept past it for the site's parking, flag `beyond_parcel`), or with `parcel_mode: :grow`, the paving inside the site's parcels taken in. | `parcels`, `parcel_mode` |
| `site_parcels` | The building's parcel holds other businesses' buildings: used only as a limit (flag `shared_parcel`). | `parcel_mode` |

New step names may be added in minor versions; treat an unknown one as a plain note.

### Confidence

`Result#confidence` orders results for review: flags say what to look at, confidence says where to look first. It's rule-based (no learning): each factor that isn't met takes its weight off 1, never below 0, rounded to 2 places. The factors are `Curtilage::Confidence::FACTORS`:

| Factor | Weight | Met when |
|---|---|---|
| `valid` | 1.0 | The premises passed validation. |
| `main_method` | 0.30 | Made by the main method (no `fallback`). |
| `building_under_pin` | 0.20 | The pin was given on the building used (no `building_not_under_pin` or `pin_moved`). |
| `full_data` | 0.20 | Map data covers the whole area around the pin (no `partial_data`). |
| `plausible_building` | 0.15 | The building is big enough to be a store (no `small_building`). |
| `mapped_parking` | 0.15 | Mapped parking is inside the premises. |
| `road_frontage` | 0.15 | At least one side of the premises runs along a public road. |
| `osm_building` | 0.10 | The building is from OpenStreetMap (no `ml_footprint`). |
| `single_building_store` | 0.10 | The building is small enough to be one store (no `large_building` or `store_may_be_unit`). |
| `no_homes_next_door` | 0.10 | No home borders the lot (no `near_houses`). |
| `own_lot` | 0.10 | The lot isn't split with other buildings (no `shared_lot`). |
| `no_warnings` | 0.05 | Validation raised no warnings. |

The weights are judgement for now, to be calibrated on the public benchmark once its reference polygons are drawn; treat the score as an order, not a probability. Data age isn't a factor, so the same inputs always score the same.

### Flags

The same list is `Curtilage::FLAGS` (flag => what it asks a person to check).

| Flag | Meaning |
|---|---|
| `near_houses` | The lot borders a home: check where the yard or property line is. |
| `large_building` | Building over 5,000 m2: may be shared by several tenants. |
| `small_building` | Building under 50 m2: may be a kiosk or canopy rather than the store. |
| `building_not_under_pin` | No building under the pin; the nearest one within 30 m was used. |
| `pin_moved` | The pin wasn't on a building and was moved onto the nearest one (`snap_m:`): check it's the right one. |
| `store_may_be_unit` | The store zone is a building over 1,500 m2: the store may be one unit of it. |
| `shopping_centre` | `scope: :centre` mapped the whole centre. |
| `large_centre` | `scope: :centre`, but the centre is over `centre_max_m2` (50,000 m2 by default): the premises are the site's own share, not the whole centre. |
| `shared_lot` | The lot is shared with other buildings and was split by nearest building: where it really divides isn't in the map, so check the line. |
| `fallback` | The main method failed validation; the building rectangle was used. |
| `ml_footprint` | Built on a machine-learned footprint, not an OSM building. |
| `unit_estimated` | The store zone is an estimated unit of a large building (`unit_m:`): check it. |
| `beyond_parcel` | The site's parking runs past the building's parcel (parcels supplied): check the property line. |
| `shared_parcel` | `parcel_mode: :grow` or `:start`: the building's parcel also holds other businesses' buildings (a centre or shared lot), so it was used only as a limit. |
| `no_data` | No map data covers the pin. |
| `error` | Generating this site raised an error (see its explanation); the rest of the batch went on. |
| `partial_data` | Part of the area around the pin is in a region that isn't built (a hand-built catalogue near a border): buildings or roads there are missing. |

### Files: `Curtilage::Formats`

Reading pins:

- `Formats.read_pins(path, format: nil)`: pins from a `.csv`, `.geojson`/`.json` or `.ndjson`/`.jsonl` file, as `[{ id:, pin: [lng, lat] }, ...]`. `Formats.parse_pins(text, :csv | :geojson | :ndjson)` does the same from a string.
- CSV: a header row, then one pin per row. Longitude is the column named `lng`, `lon`, `long` or `longitude`; latitude is `lat` or `latitude`; the id, if any, is `id`, `site_id` or `name` (names are case-insensitive). Quoted fields, a byte-order mark and blank lines are fine.
- GeoJSON: a FeatureCollection of Point features (or one Point feature). The id is the feature's `id`, or its `id` or `name` property.
- NDJSON (`.ndjson`/`.jsonl`, or `:ndjson`): one site per line, as `{"id": "a", "lng": -80.1, "lat": 35.2}` (any of the CSV column names), `{"id": "a", "pin": [-80.1, 35.2]}` or a GeoJSON Point Feature. Blank lines are skipped; a bad line is named by number.
- Pins without an id are numbered from 1. Files are capped at 50 MB and 100,000 pins; CSV fields (and ids) at 10,000 characters and rows at 1,000 columns; GeoJSON nesting at 20 levels. Files must be UTF-8 (a byte-order mark is fine) without NUL bytes.
- Coordinates must be plain decimal numbers (`-80.25`, `35`, `1e-3`), longitude first, longitude within 180 and latitude within 90. Hexadecimal, underscores (`1_0`), `NaN` and infinite values are refused with the line or feature named. Every entry point (Ruby calls, `--pin`, files) checks pins the same way.

Writing results: `Formats.write(results, format, ids: nil, store: true)` returns text.

#### GIS formats

GeoParquet (`.parquet`, GeoParquet 1.0 metadata), GeoPackage (`.gpkg`) and FlatGeobuf (`.fgb`) are binary files, written by the command line (`--out FILE`) or `Curtilage::Batch.new(format: :gpkg, out: path, duckdb: {})` then `add` and `finish`. The run streams NDJSON into `OUT.part` (so `--resume` works) and DuckDB converts it at the end, beside the target, then renames it into place. One row a site, in EPSG:4326 ([lng, lat]): `id`, `ok`, `method`, `flags` (`;`-separated), `confidence`, `building`, `area_m2`, `attribution`, `gem_version`, `data_source`, `features_sha256`, `provenance` (the full record as JSON), `store_wkt`, and the premises as `geometry` (null without premises). FlatGeobuf, meant for web maps, holds only the sites with premises: its spatial index can't take an empty geometry. Needs DuckDB's `spatial` extension (GDAL is built into it).

| Format | What |
|---|---|
| `:geojson` | One FeatureCollection: for each pin, its premises, (unless `store: false`) its store zone, and any [zones](#zones) asked for, with `properties.id`, `properties.role` and everything `to_geojson` carries. |
| `:ndjson` | One line per pin: a GeoJSON Feature of its premises (`geometry` is `null` when none could be made) with everything `to_geojson` carries in its properties, the store zone's geometry in `properties.store` (absent with `store: false`), and any [zones](#zones) in `properties.approach` and `properties.pickup`. The schema is [`docs/schema/site-v1.json`](schema/site-v1.json) (it ships in the gem); version 1 only gains optional properties, and anything that would break a reader gets a new schema version. |
| `:csv` | One row per pin. Columns: `id`, `lng`, `lat`, `ok`, `problem`, `method`, `flags` and `errors` (`;`-separated), `building`, `building_area_m2`, `parking_area_m2`, `parking_spaces_estimate`, `frontage_m`, `premises_area_m2`, `premises_wkt`, `store_wkt`, `attribution` (`; `-separated), then `gem_version`, `data_source`, `data_release` (the Overture release or the Geofabrik extract dates, `;`-separated) and `features_sha256` from `provenance` (the options are only in GeoJSON), then `confidence`, `approach_wkt`, `pickup_wkt` and `staging_wkt` (empty unless asked for), then `pin_quality` and `candidates` (how many). Cells a spreadsheet would run as a formula (starting with `=`, `+`, `-`, `@`, `|` or `%`, or their full-width forms, even after spaces) get a leading `'`; plain numbers don't. |
| `:kml` | A placemark per polygon (premises, store zone and any zones) and per point (driveway entrances, named by their street, and the staging point), with the confidence, flags, attribution, gem version and data release in its description, and every source credited in the document's description, for Google Earth. |

`Formats.write_places(places, :csv | :ndjson | :geojson)` writes places as pins: `id`, `lng`, `lat` (which `read_pins` reads back), `name`, `brand`, `category`, `place_confidence`, `place_sources`, `place_licences`.

`Formats.format_of(path)` names the format a file extension stands for.

### Preview: `Curtilage::Preview`

`Preview.html(results, ids: nil, title: "curtilage preview", buffer_m: nil, notes: nil, backgrounds: nil, background_credit: nil)` returns a self-contained HTML page with a card per result (`notes:`: one line of text per result, or nil, shown under its heading; `backgrounds:`: one image per result, or nil, drawn under its map, which must be a relative path to a `.jpg`, `.png` or `.webp` file served with the page and cover exactly the map's square, 120 m either side of the pin in plain longitude and latitude; `background_credit:` names the imagery's source on the page):

- A map 240 m across, north up, with a 50 m scale bar: the premises, store zone and pin; the site's building (darker) and other buildings, mapped parking, public roads (hover for the name), service roads and driveways, railways; driveway entrances (blue dots); with `buffer_m:`, the premises grown by that much (dashed).
- Under it: the flags (hover for their meaning), the building and premises areas, parking area and estimated spaces, street frontage, the number of entrances, and the step-by-step explanation. Invalid results say why.
- At the top, a count of sites that are ok, flagged or without usable premises, and two controls: **Show** (all sites; those that need a look, meaning flagged or not valid; not valid; ok with no flags; or those with a given flag, with counts) and **Sort by** (input order, needs a look first, lowest confidence first, id, largest or smallest premises). Each card shows its confidence. The choice is remembered in the browser. The controls are a short inline script; without it every card shows, in input order.

The surroundings come from `Result#features`, so pass results from `generate_many(pins, keep_features: true)`; without them only the premises, store zone and entrances are drawn. The page loads nothing from the internet (no tiles, scripts or fonts; background images, when given, come from the page's own folder), so opening it reveals no locations; it does contain the coordinates, so share it only as you would them. Its Content-Security-Policy allows only its own inline style and script, and text from map data is escaped.

### Other entry points

- `Curtilage::Audit.check(pin, ring, features, thresholds: {}, **options)`: checks an existing polygon. Returns a report with `verdict` (`:ok`, `:review`, `:invalid`), `reasons` (`crosses_road`, `covers_neighbour`, `differs_from_generated`, validation warnings), `overlap`, `road_m`, `neighbour_m2` and the `generated` result.
- `Curtilage::Validation.check(pin, ring, **thresholds)`: the checks every polygon goes through.
- `Curtilage::Build.run(region, out_dir:, work_dir:, **options)`: build a region's files ahead of time (`date:`, `ml_footprints:`, `memory_limit:` `"400MB"` (a size such as `"2GB"`), `threads:` `1` (1 to 64), `timeout:` `3600` seconds for the build query, `keep_downloads:`). Downloads retry network hiccups (3 tries), including a download cut short (shorter than its declared length, or an index that doesn't parse), and use `curl` when available. Each build records its region's outline from Geofabrik's index, and the size and SHA256 of every file it downloaded (`sources`, `ml_sources` in the region's `.json`); rebuilding the same dated extract warns if any of them changed.
- `Curtilage::Catalogue.from_dir(dir, base_url: nil)`: the regions built into a folder; `base_url:` when the Parquet files live in a bucket. It uses each region's recorded outline to decide which files cover a pin, and `coverage(pin)` says whether that's `:full`, `:partial` or `:none`.
- `Curtilage::Lookup.features(parquet:, pin:)` / `features_many(parquet:, pins:)`: the map features around pins, from built files.
- `Curtilage::Overture.features_many(pins)`: the map features around pins, from Overture Maps.
- `Curtilage::Overture.places(bbox:, ...)`: what `Curtilage.places` reads, for a box only.

## Data licence

Results are derived from OpenStreetMap data under the [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/), so they keep its terms, not the code's MIT licence. Credit OpenStreetMap wherever results are shown ([OSMF attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)); every output carries what to credit (`Result#attribution`, the GeoJSON `attribution` property, the CSV `attribution` column, the KML description, the preview page). Storing or publishing many results can make a derivative database with ODbL share-alike obligations (section 4.4); a map image or other produced work needs a notice (section 4.3). Overture data also credits the Overture Maps Foundation and, when used, Overture's non-OSM building sources; Microsoft's footprints are under [CDLA Permissive 2.0](https://cdla.dev/permissive-2-0/). See the README's [Data licence](../README.md#data-licence) section and the OSMF [community guidelines](https://osmfoundation.org/wiki/Licence/Community_Guidelines). Not legal advice.

## Configuration

Set once instead of passing on every call. Defaults come from the environment.

| Setting | Environment variable | Default |
|---|---|---|
| `duckdb` | `CURTILAGE_DUCKDB` | `duckdb` on the PATH |
| `extension_directory` | `CURTILAGE_EXTENSIONS` | DuckDB's own |
| `cache_dir` | `CURTILAGE_CACHE_DIR` | none (temporary folders) |
| `source` | `CURTILAGE_SOURCE` | `auto` |
| `offline` | `CURTILAGE_OFFLINE` | off. `1`: never use the network: extensions are loaded but not installed (populate the folder first, e.g. with `curtilage doctor`), every download is refused, and so are Overture and bucket reads; prebuilt catalogues and cached builds still work |
| `duckdb_timeout` | `CURTILAGE_DUCKDB_TIMEOUT` | `600` seconds per lookup or Overture query; DuckDB is then stopped, with anything it started |
| | `CURTILAGE_CURL` | Downloads use the `curl` command when it's installed (optional, much faster); `0` forces Ruby's own HTTP client |
| | `HTTPS_PROXY`, `NO_PROXY` | Downloads go through this proxy (both with and without `curl`), except to hosts `NO_PROXY` covers. DuckDB's own reads (Overture, buckets) use DuckDB's `http_proxy` setting, which `lookup: { setup_sql: }` can set. |

```ruby
Curtilage.configure do |c|
  c.cache_dir = "/var/cache/curtilage"
  c.source = :overture
end
```

DuckDB's `spatial` and `httpfs` extensions install themselves on first use.

## Command line

```
curtilage generate (--pin LNG,LAT ... | --in FILE|-) [--out FILE] [options]
curtilage preview (--pin LNG,LAT ... | --in FILE) [--out FILE] [options]
curtilage places (--region NAME | --bbox W,S,E,N) (--category NAME | --brand NAME | --place-id ID ...)
curtilage diff OLD NEW [--threshold IOU] [--out FILE]
curtilage build REGION [options]
curtilage doctor
curtilage missing-buildings (--pin LNG,LAT ... | --in FILE|-) [--out FILE] [--maproulette] [--with-ids]
```

- `generate`: premises and store zones for one or more pins.
  - Pins: `--pin LNG,LAT` (repeat for several; ids 1, 2, ...) and/or `--in FILE` (CSV, GeoJSON or NDJSON; see [Files](#files-curtilageformats)). `--in -` reads standard input, as NDJSON unless `--in-format csv|geojson|ndjson` says otherwise; `--in-format` also overrides a file's extension.
  - Output: printed as GeoJSON, or `--out FILE` in the format its extension names (`.geojson`/`.json`, `.ndjson`/`.jsonl`, `.csv`, `.kml`, `.parquet`, `.gpkg`, `.fgb`). `--format geojson|ndjson|csv|kml|geoparquet|gpkg|fgb` overrides; the last three need `--out` ([GIS formats](#gis-formats)). The file is written whole (to a temporary name, then renamed) and replaces any file there; a symbolic link at that path is refused.
  - Data: `--source auto|geofabrik|overture` (default auto), `--cache-dir DIR`, `--catalogue DIR`, `--parquet FILE`.
  - Style: `--preset whole_lot|tight|centre` or a profile name with `--profiles FILE`, `--buildings osm|osm_or_ml|osm_filled|ml`, `--[no-]store`, `--entrances near|all` (`entrances:`).
  - H3: `--h3 RES` lists the H3 cells each premises touches ([H3](#curtilageh3coverresults-resolution-lookup--results)).
  - Geofences: `--simplify N` keeps at most N corners per premises, never dropping the pin or store zone (`Result#simplified`). Every GeoJSON/NDJSON premises carries `enclosing_circle` and `fit_circle`; CSV has `circle_*` and `fit_*` columns.
  - Parcels: `--parcels FILE` clips premises to your property lines ([Parcels](#parcels)).
  - Corrections: `--corrections FILE` uses your polygons for sites with the same id ([Corrections](#corrections-and-comparing-runs)).
  - Ambiguous sites: `--candidates N` (1 to 5) adds up to N other premises ([Candidates](#candidates)).
  - Pins: `--snap [METRES]` (default 30) moves pins that aren't on a building onto the nearest one (`snap_m:`).
  - Zones: `--approach [METRES]` (default 150) and `--pickup [METRES]` (default 25) add the [zones](#zones).
  - DuckDB: `--duckdb PATH`, `--extension-directory DIR`.
  - Big batches: sites are generated in chunks of 500 (`Curtilage::Batch`). NDJSON and CSV are written as each chunk finishes, so memory stays flat: to standard output directly, or with `--out FILE` into `.FILE.part` next to it, renamed to `FILE` when the run finishes (so `FILE` never holds half a run). `--resume` carries on an interrupted run from that `.part` file, skipping sites already in it and redoing a line cut short by a crash; it needs `--out` with `.ndjson` or `.csv` and unique site ids. GeoJSON and KML are written whole at the end. Progress (sites done, rate, time left) goes to standard error when it's a terminal, or always with `--progress`. Without `--cache-dir`, a Geofabrik region the run builds is kept in a temporary cache for the whole run, so chunks don't rebuild it.
  - `--min-confidence N` (0 to 1) leaves out results whose confidence is below N, and says how many on standard error; the exit code is then 1, as some sites weren't written.
  - Logs: `--quiet` keeps only warnings and errors; `--log-format json` writes each log line as `{"level": "info"|"warning"|"error", "message": "..."}`.
- `preview`: generates the same way (same options, except `--format`), then writes the page described under [Preview](#preview-curtilagepreview). `--out FILE` (default `curtilage-preview.html`); `--buffer METRES` also draws the premises grown by that much.
- `diff OLD NEW`: compares two result files ([Comparing runs](#corrections-and-comparing-runs)). `--threshold IOU` (default 0.9), `--out FILE`, `--format csv|ndjson`. Exits 1 when any site needs review.
- `places (--region NAME | --bbox W,S,E,N) (--category NAME | --brand NAME | --place-id ID ...)`: pins from Overture Maps places (`Curtilage.places`), as CSV (default), NDJSON or GeoJSON, printed or `--out FILE`. Also `--min-confidence N`, `--release NAME`, the DuckDB and log flags. Its output feeds `generate --in` directly: `curtilage places --region delaware --category pharmacy | curtilage generate --in - --in-format csv`.
- `build REGION` writes `REGION.parquet` and `REGION.json`. REGION is a US state (`tennessee`, `new-york`) or a Geofabrik path (`europe/germany/bayern`). Options: `--out DIR` (default `.`), `--work DIR` (default: a private temporary folder, removed afterwards), `--date YYMMDD`, `--keep-downloads`, `--ml-footprints microsoft`, `--duckdb`, `--extension-directory`.
- `serve`: an HTTP API ([HTTP server](#http-server-curtilage-serve)).
- `missing-buildings`: the sites where OpenStreetMap has no building near the pin, as a task list for mappers: GeoJSON points, printed or `--out FILE`. It always uses OSM buildings only (`buildings: :osm`), so a machine-learned footprint can't hide the gap. Sites with no map data, partial data or an error are left out. Each task says what to do and has `footprint_nearby`: whether a machine-learned footprint (when the data has them) lies within 30 m, i.e. there's probably something to trace. Site ids stay out unless `--with-ids`. `--maproulette` writes one task per line in the format MapRoulette's line-by-line upload takes (RFC 7464: each line a FeatureCollection, after a record separator). Takes the same data, DuckDB and log flags as `generate`. In Ruby: `Curtilage::MissingBuildings.features(results, ids, with_ids: false)` on results from `generate_many(..., keep_features: true)`, and `.write(features, maproulette: false)`. **A list of where your sites are can be private: check before sharing it or uploading it as a public challenge.**
- `doctor` checks everything the gem needs outside Ruby, with a fix for each problem: the DuckDB binary (its path and version; a warning, not a failure, outside the tested 1.4 LTS and 2.0), its `spatial` and `httpfs` extensions (with versions), and the cache folder's permissions when one is configured. `--verify DIR` also checks every built file in a catalogue or cache folder against the SHA256 its build recorded; `--network` checks that Geofabrik and Overture's catalogue answer (no locations are sent); `--json` prints the report for scripts. It exits 0 when ready, 1 if not. It prints the DuckDB version and the path of the binary that runs: `CURTILAGE_DUCKDB` runs whatever it names, so it's trusted configuration.

Run `curtilage COMMAND --help` for the same list.

Standard output carries only results (`generate` without `--out`, and the file path `build` wrote); progress, summaries, warnings and errors go to standard error, so output can be piped. Exit codes, for `generate`, `preview`, `places`, `diff` and `build` (`diff` uses 1 for "some sites need review"):

| Code | Meaning |
|---|---|
| 0 | Done; every site has usable premises. |
| 1 | Done, but some sites have no usable premises (`ok` is false); the output was still written. |
| 2 | Bad input or usage: an unknown option or command, a bad pin, an unreadable input file, an output path that can't be written. Nothing was generated. |
| 3 | A dependency is missing: DuckDB isn't found, or its extensions won't load. `curtilage doctor` says what to fix. |
| 4 | Map data unavailable: a download, Overture read or build failed, offline mode forbids what's needed, or a built file can't be read. |
| 70 | An unexpected error (a bug: please report it with the message). |

`doctor` keeps its own codes: 0 ready, 1 not.

### HTTP server: `curtilage serve`

`curtilage serve [--host HOST] [--port PORT]` (default 127.0.0.1:8754) answers HTTP on the standard library alone (no server gem), so any language can ask for premises. The spec is [docs/openapi.yaml](openapi.yaml).

- `GET /health`: `{"status":"ok"}`, no token needed. `GET /version`: the gem, DuckDB and the default data source.
- `POST /premises`: `{"pins": [[lng, lat], ...] or [{"id": ..., "pin": [lng, lat]}], "options": {...}}`, a GeoJSON FeatureCollection of points, or NDJSON (`Content-Type: application/x-ndjson`). Answers a GeoJSON FeatureCollection, or NDJSON (one site per line, [schema](schema/site-v1.json)) with `Accept: application/x-ndjson`. A request may set generation options only (and `preset`, `candidates`, `method`); where map data comes from is fixed at start (`--source`, `--catalogue`, `--parquet`, `--cache-dir`), so a request can't point the server at files.
- **Safe by default.** Listens on 127.0.0.1 unless `--host`. With a token in `$CURTILAGE_SERVE_TOKEN` (or the variable `--token-env` names; never on the command line, where the process list shows it) every endpoint but `/health` needs `Authorization: Bearer TOKEN`, compared in constant time; a warning is printed when listening beyond this machine without one. Limits: `--max-body` (1,000,000 bytes, 413 over), `--max-pins` (100 a request, 413), `--timeout` (120 s a request, 504), `--concurrency` (4 requests at once, 503 beyond), headers 16 KB, 10 s to send a request (408); bodies need `Content-Length` (411 for chunked). No CORS headers unless `--cors-origin ORIGIN`. Errors are `{"error": "..."}`, never a stack trace. The log has one line a request (method, path, status, time) and never the pins, unless `--log-pins`.
- **TLS:** it speaks plain HTTP. To serve beyond this machine, put a reverse proxy in front and keep the server on 127.0.0.1, e.g. with Caddy (`reverse_proxy 127.0.0.1:8754` in a site block gets certificates itself) or nginx (`proxy_pass http://127.0.0.1:8754;` in a `server` block with `ssl_certificate`). Set a token too: the proxy only adds encryption.
- **Docker:** `docker run --rm -p 127.0.0.1:8754:8754 -e CURTILAGE_SERVE_TOKEN -v curtilage-cache:/cache curtilage serve --host 0.0.0.0` (inside the container it must listen on all addresses; publish the port on 127.0.0.1 or behind your proxy). The image has a health check on `/health`.

### Docker

The repository's `Dockerfile` packages the gem with the DuckDB CLI (1.4.4, checked against its SHA256; to change the version pass `--build-arg DUCKDB_VERSION=` with `DUCKDB_SHA256_AMD64=` and `DUCKDB_SHA256_ARM64=` for that release) and its extensions, fetched while building, on a base image pinned by digest. The image runs `curtilage`:

```sh
docker build -t curtilage .
docker run --rm -v "$PWD:/work" -v curtilage-cache:/cache curtilage generate --in pins.csv --out premises.csv
```

The container's working folder is `/work`: mount yours there and give file names relative to it. On-demand builds go to `/cache` (`CURTILAGE_CACHE_DIR`); mount a volume there to reuse them for a month. It runs as a non-root user, has no build tools (curl, unzip) in it, works offline (`-e CURTILAGE_OFFLINE=1`, with prebuilt files or a cache) and with a read-only root filesystem (`--read-only --tmpfs /tmp -v curtilage-cache:/cache`).
