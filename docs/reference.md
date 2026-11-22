# Reference

Everything curtilage offers, in one place. For an overview, see the [README](../README.md).

## Ruby API

### `Curtilage.premises(pin, **options) → Result`

The simplest call: premises for one `[lng, lat]` pin, fetching map data as configured. Takes the same options as `generate_many`.

### `Curtilage.generate_many(pins, **options) → [Result]`

Premises for many pins, in pin order. Pins that share map data share the work.

| Option | Default | What |
|---|---|---|
| `source:` | `Curtilage.config.source` (`:auto`) | `:auto`: build a Geofabrik region when enough pins share it (`data: { auto_build_min_pins: 10 }`) or it's already cached, and read scattered pins from Overture Maps. `:geofabrik`: always build the pins' regions (the host learns only the region). `:overture`: always read Overture Maps in place. |
| `cache_dir:` | `Curtilage.config.cache_dir` (none) | Keep on-demand builds here and reuse them for a month. Without it, builds go to a temporary folder deleted afterwards. |
| `catalogue:` | none | A `Curtilage::Catalogue` of regions built ahead of time (overrides `source:`). |
| `parquet:` | none | One built file, or a list, local or `s3://`, `gs://`, `https://` (overrides `source:`). |
| `lookup:` | `{}` | `duckdb:`, `extension_directory:` (default: the configuration), `setup_sql:` (e.g. `CREATE SECRET` for a private bucket), `radius_deg:` (how far around each pin to read, default 0.004). |
| `data:` | `{}` | For builds: `max_age_days:` (31), `ml_footprints:` (`"microsoft"`), `parallel_builds:` (1; each build peaks near 600 MB, so raise it to 2-3 only on machines with the memory). For `:auto`: `auto_build_min_pins:` (10). For Overture: `release:` (default: the latest). |
| `preset:` | none | `:whole_lot`, `:tight` or `:centre` (below). |
| `method:` | none | `:grow_trim`, `:building` or `:box` to force one method, no fallback. |
| any generation option | | See the table below. |

### `Curtilage.generate(pin, features, **options) → Result`

Premises from features you already have (from `Curtilage::Lookup.features` or `Curtilage::Overture.features_many`), with the same `preset:`, `method:` and generation options.

### `Result`

| Field | What |
|---|---|
| `ok?` | The premises passed validation. Never save one that isn't. |
| `ring` | The premises: `[[lng, lat], ...]`, closed, convex, at most `max_vertices` corners. `nil` if nothing could be made. |
| `store_ring` | The store zone: the building's own outline, always inside `ring`. `nil` with `store_zone: false`. |
| `flags` | Reasons a person should look first (below). |
| `explanation` | Each step, in plain words. |
| `validation` | `errors`, `warnings` and `metrics` (area, rectangularity, pin inside, distances). |
| `method_name` | `:grow_trim`, or `:building` after a fallback. |
| `building` | The id of the building used. |
| `to_geojson(include_store: false)` | A GeoJSON Feature (premises) with everything above in its properties, including the attribution to show; with `include_store: true`, a FeatureCollection of premises and store zone (`properties.role`). |

### Presets

| Preset | What |
|---|---|
| `:whole_lot` | The default: the building and its whole customer-facing lot. |
| `:tight` | The building plus an 8 m margin, still trimmed at roads. |
| `:centre` | Like `:whole_lot`, but a store on a shared shopping-centre lot gets the whole centre (flag `shopping_centre`). |

Any option passed with a preset overrides it.

### Generation options

All distances in metres, areas in square metres. These are `Curtilage::Generator::DEFAULTS`.

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
| `box_side_m` | `60` | Side of the baseline `:box` method's square. |
| `max_vertices` | `10` | The premises are simplified to at most this many corners (never cutting the building). |
| `max_store_vertices` | `20` | The store outline is simplified to at most this many corners. |

### Flags

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

### Other entry points

- `Curtilage::Audit.check(pin, ring, features, thresholds: {}, **options)`: checks an existing polygon. Returns a report with `verdict` (`:ok`, `:review`, `:invalid`), `reasons` (`crosses_road`, `covers_neighbour`, `differs_from_generated`, validation warnings), `overlap`, `road_m`, `neighbour_m2` and the `generated` result.
- `Curtilage::Validation.check(pin, ring, **thresholds)`: the checks every polygon goes through.
- `Curtilage::Build.run(region, out_dir:, work_dir:, **options)`: build a region's files ahead of time (`date:`, `ml_footprints:`, `memory_limit:` `"400MB"`, `threads:` `1`, `keep_downloads:`). Downloads retry network hiccups (3 tries) and use `curl` when available. Each build records its region's outline from Geofabrik's index.
- `Curtilage::Catalogue.from_dir(dir, base_url: nil)`: the regions built into a folder; `base_url:` when the Parquet files live in a bucket. It uses each region's recorded outline to decide which files cover a pin, and `coverage(pin)` says whether that's `:full`, `:partial` or `:none`.
- `Curtilage::Lookup.features(parquet:, pin:)` / `features_many(parquet:, pins:)`: the map features around pins, from built files.
- `Curtilage::Overture.features_many(pins)`: the map features around pins, from Overture Maps.

## Configuration

Set once instead of passing on every call. Defaults come from the environment.

| Setting | Environment variable | Default |
|---|---|---|
| `duckdb` | `CURTILAGE_DUCKDB` | `duckdb` on the PATH |
| `extension_directory` | `CURTILAGE_EXTENSIONS` | DuckDB's own |
| `cache_dir` | `CURTILAGE_CACHE_DIR` | none (temporary folders) |
| `source` | `CURTILAGE_SOURCE` | `auto` |
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
curtilage generate --pin LNG,LAT [--pin LNG,LAT ...] [options]
curtilage build REGION [options]
curtilage doctor
```

- `generate` prints GeoJSON (premises and store zone; several pins print a list). Options: `--source auto|geofabrik|overture` (default auto), `--cache-dir DIR`, `--catalogue DIR`, `--parquet FILE`, `--preset NAME`, `--buildings FLAVOUR`, `--[no-]store`, `--duckdb PATH`, `--extension-directory DIR`. Exits 1 if any result isn't usable.
- `build REGION` writes `REGION.parquet` and `REGION.json`. REGION is a US state (`tennessee`, `new-york`) or a Geofabrik path (`europe/germany/bayern`). Options: `--out DIR` (default `.`), `--work DIR`, `--date YYMMDD`, `--keep-downloads`, `--ml-footprints microsoft`, `--duckdb`, `--extension-directory`.
- `doctor` checks that DuckDB runs and its extensions load, and says what to install if not.

Run `curtilage COMMAND --help` for the same list.
