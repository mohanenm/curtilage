# Reference

Everything curtilage offers, in one place. For an overview, see the [README](../README.md). This is the public API: anything not listed here is internal and may change without notice.

## Ruby API

### `Curtilage.premises(pin, **options) → Result`

The simplest call: premises for one `[lng, lat]` pin, fetching map data as configured. Takes the same options as `generate_many`.

### `Curtilage.building_at(pin, **options) → Hash or nil`

Just the building at a pin (the one its premises would be made from): `{ id:, name:, type:, area_m2:, footprint: }`, with `footprint` a closed `[[lng, lat], ...]` ring. `nil` if there is none. Same options as `premises`.

### `Curtilage.generate_many(pins, **options) → [Result]`

Premises for many pins, in pin order. Pins that share map data share the work.

| Option | Default | What |
|---|---|---|
| `source:` | `Curtilage.config.source` (`:auto`) | `:auto`: build a Geofabrik region when enough pins share it (`data: { auto_build_min_pins: 10 }`) or it's already cached, and read scattered pins from Overture Maps. `:geofabrik`: always build the pins' regions (the host learns only the region; use this for sensitive location lists). `:overture`: always read Overture Maps in place (its storage host learns roughly where each pin is). See the README's [Privacy](../README.md#privacy) section. |
| `cache_dir:` | `Curtilage.config.cache_dir` (none) | Keep on-demand builds here and reuse them for a month. Without it, builds go to a temporary folder deleted afterwards. A new folder is created readable only by you; one another user owns, or that everyone can write to, is refused. A cached file that's missing or the wrong size is rebuilt. |
| `catalogue:` | none | A `Curtilage::Catalogue` of regions built ahead of time (overrides `source:`). |
| `parquet:` | none | One built file, or a list, local or `s3://`, `gs://`, `https://` (overrides `source:`). |
| `lookup:` | `{}` | `duckdb:`, `extension_directory:` (default: the configuration), `setup_sql:` (e.g. `CREATE SECRET` for a private bucket), `radius_deg:` (how far around each pin to read, default 0.004), `memory_limit:` (DuckDB's memory cap for lookups and Overture reads, default `"1GB"`), `timeout:` (seconds before a DuckDB query is stopped, default `Curtilage.config.duckdb_timeout`, 600). |
| `data:` | `{}` | For builds: `max_age_days:` (31), `ml_footprints:` (`"microsoft"`), `parallel_builds:` (1; each build peaks near 600 MB, so raise it to 2-3 only on machines with the memory). For `:auto`: `auto_build_min_pins:` (10). For Overture: `release:` (default: the latest; a release name such as `"2026-11-18.0"`). `log:` where build progress goes (anything with `puts`; default standard error). |
| `preset:` | none | `:whole_lot`, `:tight` or `:centre` (below). |
| `method:` | none | `:grow_trim` or `:building` to force one method, no fallback. |
| `keep_features:` | `false` | Keep each result's map data in `Result#features` (needed by `Preview` to draw the surroundings). Off by default to save memory on big batches. |
| any generation option | | See the table below. |

### `Curtilage.generate(pin, features, **options) → Result`

Premises from features you already have (from `Curtilage::Lookup.features` or `Curtilage::Overture.features_many`), with the same `preset:`, `method:` and generation options.

### `Result`

| Field | What |
|---|---|
| `ok?` | The premises passed validation. Never save one that isn't. |
| `problem` | Why they aren't usable, in words (e.g. `"no premises: no building within 30 m of the pin (it may be missing from OpenStreetMap: try buildings: :osm_filled)"`), or `nil` when `ok?`. |
| `ring` | The premises: `[[lng, lat], ...]`, closed, convex, at most `max_vertices` corners. `nil` if nothing could be made. |
| `store_ring` | The store zone: the building's own outline, always inside `ring`. `nil` with `store_zone: false`. |
| `flags` | Reasons a person should look first (below). |
| `explanation` | Each step, in plain words. |
| `validation` | `errors`, `warnings` and `metrics` (area, rectangularity, pin inside, distances). |
| `method_name` | `:grow_trim`, or `:building` after a fallback. |
| `building` | The id of the building used. |
| `attribution` | What to credit wherever the result is shown: OpenStreetMap, plus Overture, Overture's non-OSM building sources or Microsoft's footprints when the result could use them. `nil` means OpenStreetMap only (`Result::OSM_ATTRIBUTION`). |
| `pin` | The pin it was made for. |
| `details` | Facts about the site, rough by nature (open map data); `nil` when no premises were made. See below. |
| `features` | The map data it was made from (`Curtilage::Features`, in metres around the pin), or `nil` unless `keep_features: true`. |
| `to_geojson(include_store: false, properties: {})` | A GeoJSON Feature (premises) with everything above in its properties, including the attribution to show; with `include_store: true`, a FeatureCollection of premises and store zone (`properties.role`). `properties:` are merged into each feature's properties (your own id, say). |
| `to_wkt`, `store_wkt` | The premises and store zone as well-known text (`POLYGON ((lng lat, ...))`), for databases and spreadsheets. |
| `buffered(metres)` | The premises grown (positive) or shrunk (negative) evenly, as a closed ring: a geofence with a margin. Corners are rounded when growing. `nil` if there are no premises or they shrink away. |

`details`:

| Key | What |
|---|---|
| `building` | `{ id:, name:, type:, area_m2:, footprint: }`: the building used (`type` is OSM's `building=*` value). |
| `parking_area_m2` | Mapped parking inside the premises. |
| `parking_spaces_estimate` | That area over 25 m2 a space (aisles included). Unmapped parking counts as none. |
| `frontage_m` | Length of premises edges running along a public road. |
| `access_points` | `[[lng, lat], ...]`: where driveways taken into the premises meet the street (entrances within 10 m are counted once). |

### Errors

Every error the gem raises on purpose is a `Curtilage::Error` (or a subclass: `Lookup::Error`, `Overture::Error`, `Build::Error`, `Download::Error`, `Footprints::Error`, `ZipRange::Unsupported`, `ZipRange::Corrupt`), so `rescue Curtilage::Error` catches them all. Mistakes in what you pass (a bad pin, option or file) raise `ArgumentError`. A missing DuckDB binary is a `Curtilage::Error` saying what to install.

### Presets

| Preset | What |
|---|---|
| `:whole_lot` | The default: the building and its whole customer-facing lot. |
| `:tight` | The building plus an 8 m margin, still trimmed at roads. |
| `:centre` | Like `:whole_lot`, but a store on a shared shopping-centre lot gets the whole centre (flag `shopping_centre`). |

Any option passed with a preset overrides it.

### Generation options

All distances in metres, areas in square metres. These are `Curtilage::Generator::DEFAULTS`. An unknown or misspelt option raises `ArgumentError`, and so does a value out of range: distances must be 0 to 1,000 m, areas 0 to 10,000,000 m2, `max_vertices` a whole number from 4 to 50, `max_store_vertices` from 3 to 200, `shared_lot_buildings` from 1 to 1,000 (`Generator::RANGES`).

| Option | Default | What |
|---|---|---|
| `store_zone` | `true` | Also return the building's outline as the store zone. |
| `buildings` | `:osm` | `:osm`, `:osm_filled` (machine-learned footprints only where OSM has no building) or `:ml`. |
| `scope` | `:site` | `:site`, or `:centre` for the whole shopping centre when on a shared lot. |
| `grow_m` | `30` | How far the building's rectangle grows toward its lot before trimming. |
| `road_offset_m` | `nil` | How far short of road centrelines to stop; `nil` uses half a typical road width by class. |
| `building_clearance_m` | `3` | Road trims stop at least this far from the building. |
| `neighbour_gap_m` | `3` | Strip left to a neighbouring building; `nil` splits halfway. |
| `neighbour_min_area_m2` | `40` | Smaller buildings (sheds) don't bound the lot. |
| `neighbour_strip_min_area_m2` | `0` | Neighbours smaller than this are split halfway instead of getting the strip. |
| `house_max_m2` | `250` | An untyped building smaller than this, among other small ones, counts as a home. |
| `house_street_m` | `25` | ... when two more small buildings are this close. |
| `parking_reach_m` | `20` | Mapped parking this close to the building is its lot. |
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

### Flags

The same list is `Curtilage::FLAGS` (flag => what it asks a person to check).

| Flag | Meaning |
|---|---|
| `near_houses` | The lot borders a home: check where the yard or property line is. |
| `large_building` | Building over 5,000 m2: may be shared by several tenants. |
| `small_building` | Building under 50 m2: may be a kiosk or canopy rather than the store. |
| `building_not_under_pin` | No building under the pin; the nearest one within 30 m was used. |
| `store_may_be_unit` | The store zone is a building over 1,500 m2: the store may be one unit of it. |
| `shopping_centre` | `scope: :centre` mapped the whole centre. |
| `fallback` | The main method failed validation; the building rectangle was used. |
| `ml_footprint` | Built on a machine-learned footprint, not an OSM building. |
| `no_data` | No map data covers the pin. |
| `partial_data` | Part of the area around the pin is in a region that isn't built (a hand-built catalogue near a border): buildings or roads there are missing. |

### Files: `Curtilage::Formats`

Reading pins:

- `Formats.read_pins(path)`: pins from a `.csv` or `.geojson`/`.json` file, as `[{ id:, pin: [lng, lat] }, ...]`. `Formats.parse_pins(text, :csv | :geojson)` does the same from a string.
- CSV: a header row, then one pin per row. Longitude is the column named `lng`, `lon`, `long` or `longitude`; latitude is `lat` or `latitude`; the id, if any, is `id`, `site_id` or `name` (names are case-insensitive). Quoted fields, a byte-order mark and blank lines are fine.
- GeoJSON: a FeatureCollection of Point features (or one Point feature). The id is the feature's `id`, or its `id` or `name` property.
- Pins without an id are numbered from 1. Files are capped at 50 MB and 100,000 pins; CSV fields (and ids) at 10,000 characters and rows at 1,000 columns; GeoJSON nesting at 20 levels. Files must be UTF-8 (a byte-order mark is fine) without NUL bytes.
- Coordinates must be plain decimal numbers (`-80.25`, `35`, `1e-3`), longitude first, longitude within 180 and latitude within 90. Hexadecimal, underscores (`1_0`), `NaN` and infinite values are refused with the line or feature named. Every entry point (Ruby calls, `--pin`, files) checks pins the same way.

Writing results: `Formats.write(results, format, ids: nil, store: true)` returns text.

| Format | What |
|---|---|
| `:geojson` | One FeatureCollection: for each pin, its premises and (unless `store: false`) its store zone, with `properties.id`, `properties.role` and everything `to_geojson` carries. |
| `:csv` | One row per pin. Columns: `id`, `lng`, `lat`, `ok`, `problem`, `method`, `flags` and `errors` (`;`-separated), `building`, `building_area_m2`, `parking_area_m2`, `parking_spaces_estimate`, `frontage_m`, `premises_area_m2`, `premises_wkt`, `store_wkt`, `attribution` (`; `-separated). Cells a spreadsheet would run as a formula (starting with `=`, `+`, `-`, `@`, `|` or `%`, or their full-width forms, even after spaces) get a leading `'`; plain numbers don't. |
| `:kml` | A placemark per polygon (premises and store zone), with the flags and attribution in its description, and every source credited in the document's description, for Google Earth. |

`Formats.format_of(path)` names the format a file extension stands for.

### Preview: `Curtilage::Preview`

`Preview.html(results, ids: nil, title: "curtilage preview", buffer_m: nil)` returns a self-contained HTML page with a card per result:

- A map 240 m across, north up, with a 50 m scale bar: the premises, store zone and pin; the site's building (darker) and other buildings, mapped parking, public roads (hover for the name), service roads and driveways, railways; driveway entrances (blue dots); with `buffer_m:`, the premises grown by that much (dashed).
- Under it: the flags (hover for their meaning), the building and premises areas, parking area and estimated spaces, street frontage, the number of entrances, and the step-by-step explanation. Invalid results say why.
- At the top, a count of sites that are ok, flagged or without usable premises, and two controls: **Show** (all sites; those that need a look, meaning flagged or not valid; not valid; ok with no flags; or those with a given flag, with counts) and **Sort by** (input order, needs a look first, id, largest or smallest premises). The choice is remembered in the browser. The controls are a short inline script; without it every card shows, in input order.

The surroundings come from `Result#features`, so pass results from `generate_many(pins, keep_features: true)`; without them only the premises, store zone and entrances are drawn. The page loads nothing from the internet (no tiles, scripts or fonts), so opening it reveals no locations; it does contain the coordinates, so share it only as you would them. Its Content-Security-Policy allows only its own inline style and script, and text from map data is escaped.

### Other entry points

- `Curtilage::Audit.check(pin, ring, features, thresholds: {}, **options)`: checks an existing polygon. Returns a report with `verdict` (`:ok`, `:review`, `:invalid`), `reasons` (`crosses_road`, `covers_neighbour`, `differs_from_generated`, validation warnings), `overlap`, `road_m`, `neighbour_m2` and the `generated` result.
- `Curtilage::Validation.check(pin, ring, **thresholds)`: the checks every polygon goes through.
- `Curtilage::Build.run(region, out_dir:, work_dir:, **options)`: build a region's files ahead of time (`date:`, `ml_footprints:`, `memory_limit:` `"400MB"` (a size such as `"2GB"`), `threads:` `1` (1 to 64), `timeout:` `3600` seconds for the build query, `keep_downloads:`). Downloads retry network hiccups (3 tries) and use `curl` when available. Each build records its region's outline from Geofabrik's index, and the size and SHA256 of every file it downloaded (`sources`, `ml_sources` in the region's `.json`); rebuilding the same dated extract warns if any of them changed.
- `Curtilage::Catalogue.from_dir(dir, base_url: nil)`: the regions built into a folder; `base_url:` when the Parquet files live in a bucket. It uses each region's recorded outline to decide which files cover a pin, and `coverage(pin)` says whether that's `:full`, `:partial` or `:none`.
- `Curtilage::Lookup.features(parquet:, pin:)` / `features_many(parquet:, pins:)`: the map features around pins, from built files.
- `Curtilage::Overture.features_many(pins)`: the map features around pins, from Overture Maps.

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
| `duckdb_timeout` | `CURTILAGE_DUCKDB_TIMEOUT` | `600` seconds per lookup or Overture query; DuckDB is then stopped, with anything it started |
| | `CURTILAGE_CURL` | Downloads use the `curl` command when installed (much faster); `0` forces Ruby's own HTTP client |

```ruby
Curtilage.configure do |c|
  c.cache_dir = "/var/cache/curtilage"
  c.source = :overture
end
```

DuckDB's `spatial` and `httpfs` extensions install themselves on first use.

## Command line

```
curtilage generate (--pin LNG,LAT ... | --in FILE) [--out FILE] [options]
curtilage preview (--pin LNG,LAT ... | --in FILE) [--out FILE] [options]
curtilage build REGION [options]
curtilage doctor
```

- `generate`: premises and store zones for one or more pins.
  - Pins: `--pin LNG,LAT` (repeat for several; ids 1, 2, ...) and/or `--in FILE` (CSV or GeoJSON; see [Files](#files-curtilageformats)).
  - Output: printed as GeoJSON, or `--out FILE` in the format its extension names (`.geojson`/`.json`, `.csv`, `.kml`). `--format geojson|csv|kml` overrides. The file is written whole (to a temporary name, then renamed) and replaces any file there; a symbolic link at that path is refused.
  - Data: `--source auto|geofabrik|overture` (default auto), `--cache-dir DIR`, `--catalogue DIR`, `--parquet FILE`.
  - Style: `--preset whole_lot|tight|centre`, `--buildings osm|osm_filled|ml`, `--[no-]store`.
  - DuckDB: `--duckdb PATH`, `--extension-directory DIR`.
  - Exits 1 if any result isn't usable, so scripts can tell.
- `preview`: generates the same way (same options, except `--format`), then writes the page described under [Preview](#preview-curtilagepreview). `--out FILE` (default `curtilage-preview.html`); `--buffer METRES` also draws the premises grown by that much.
- `build REGION` writes `REGION.parquet` and `REGION.json`. REGION is a US state (`tennessee`, `new-york`) or a Geofabrik path (`europe/germany/bayern`). Options: `--out DIR` (default `.`), `--work DIR` (default: a private temporary folder, removed afterwards), `--date YYMMDD`, `--keep-downloads`, `--ml-footprints microsoft`, `--duckdb`, `--extension-directory`.
- `doctor` checks that DuckDB runs and its extensions load, and says what to install if not. `--verify DIR` also checks every built file in a catalogue or cache folder against the SHA256 its build recorded. It prints the DuckDB version and the path of the binary that runs: `CURTILAGE_DUCKDB` runs whatever it names, so it's trusted configuration.

Run `curtilage COMMAND --help` for the same list.

### Docker

The repository's `Dockerfile` packages the gem with the DuckDB CLI (1.4.4, `--build-arg DUCKDB_VERSION=` to change) and its extensions, fetched while building. The image runs `curtilage`:

```sh
docker build -t curtilage .
docker run --rm -v "$PWD:/work" -v curtilage-cache:/cache curtilage generate --in pins.csv --out premises.csv
```

The container's working folder is `/work`: mount yours there and give file names relative to it. On-demand builds go to `/cache` (`CURTILAGE_CACHE_DIR`); mount a volume there to reuse them for a month. It runs as a non-root user.
