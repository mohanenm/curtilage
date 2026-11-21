# curtilage

*Curtilage: the land immediately around a building, such as its yard, drive and lot.*

Generates a site's **premises polygon** (the building plus its pickup and parking area) from OpenStreetMap data, so nobody has to draw it by hand.

**Status:** early. Build, lookup, generation and validation work; the method is being evaluated against hand-drawn premises.

## How it works

1. **Build** (once a month per region, in the background). `curtilage build tennessee` downloads the region's newest dated OpenStreetMap shapefiles from [Geofabrik](https://download.geofabrik.de/), keeps buildings, parking, drivable roads and railways, and writes one Parquet file sorted by location. Any US state works, and so does any Geofabrik region path (`europe/germany/bayern`). With memory capped at 400 MB and 1 thread, so it fits a 1 GB dyno: mid-size states take 1-2 minutes including the download, and Texas (6.3M buildings) 268 s, all under 650 MB peak.
2. **Look up.** Read the features around a point from that file: about 5 ms of query, or about 85 ms per call through the DuckDB CLI, because only the row groups near the point are read.
3. **Generate.** Propose a polygon from the building under the pin: grow its rectangle toward the lot, then trim at the kerb of public roads, at railways and short of neighbouring buildings, and take in mapped parking that touches the building. If that fails validation, fall back to the building's rectangle plus a margin. Each result carries an explanation of every step and review flags (a large or attached building, no building under the pin, a fallback).
4. **Validate.** Reject or flag polygons that are unsafe to use: pin outside, unclosed, self-intersecting, swapped coordinates, too far from the pin, an implausible size.

Nothing calls an outside service at runtime. The only network access is the build's download of public map files (Geofabrik, and Microsoft's footprint files if asked for).

Coordinates are `[lng, lat]` throughout, as in GeoJSON.

## Layout

| Path | What |
|---|---|
| `lib/curtilage/geometry.rb` | Plain-Ruby planar geometry (area, containment, hull, minimum rotated rectangle) |
| `lib/curtilage/validation.rb` | Checks a polygon against its pin, returning errors, warnings and metrics |
| `lib/curtilage/features.rb` | Parses nearby OSM features (untrusted) and projects them to metres |
| `lib/curtilage/generator.rb` | Generation methods, the fallback chain and review flags |
| `lib/curtilage/lookup.rb` | Reads the features around a pin from a features Parquet file via the DuckDB CLI |
| `lib/curtilage/build.rb` | Downloads a region's Geofabrik shapefiles and builds its features Parquet file |
| `lib/curtilage/footprints.rb` | Optional machine-learned building footprints (Microsoft) |
| `lib/curtilage/download.rb` | HTTPS downloads from allowed hosts, with size caps |
| `lib/curtilage/catalogue.rb` | Finds the built region file(s) covering a pin |
| `lib/curtilage/regions.rb` | Geofabrik's region index: which region a pin is in |
| `lib/curtilage/auto_data.rb` | Builds the regions pins need on demand, into a temporary or cache folder |
| `lib/curtilage/overture.rb` | Reads features in place from Overture Maps' public release |
| `lib/curtilage/zip_range.rb` | Downloads only the needed files from a remote zip |
| `lib/curtilage/audit.rb` | Checks an existing polygon against the map and the generated one |
| `exe/curtilage` | `curtilage build REGION` and `curtilage generate --parquet FILE --pin LNG,LAT` (prints GeoJSON) |
| `sql/build_from_shapefiles.sql` | DuckDB query: Geofabrik shapefiles to a features Parquet file |
| `test/` | Tests, using synthetic coordinates only |

## Building footprints: OSM, or OSM plus machine-learned

By default everything comes from OpenStreetMap, and the method is plain rules: no machine learning anywhere. Where OSM is missing buildings, you can opt in to [Microsoft's Global ML Building Footprints](https://github.com/microsoft/GlobalMLBuildingFootprints) (ODbL, like OSM):

- Build with `--ml-footprints microsoft` (or `ml_footprints: "microsoft"`) to add them to the Parquet file.
- Generate with `buildings:`
  - `:osm` (default): OSM buildings only.
  - `:osm_filled`: OSM buildings, plus ML footprints where OSM has no building.
  - `:ml`: ML footprints only, for comparison.

A result built on an ML footprint says so in its explanation and carries the `ml_footprint` flag.

## Usage

With no setup at all, `generate_many` builds what it needs: it finds each pin's region from Geofabrik's region index, downloads and builds only those regions, and cleans up afterwards. Nothing has to be hosted:

```ruby
results = Curtilage.generate_many(pins)                              # temporary data, deleted after
results = Curtilage.generate_many(pins, cache_dir: "/var/cache/cl")  # reuse builds for a month
```

That suits background jobs (a US state takes 1-5 minutes the first time; Rhode Island took 25 s end to end).

Or read from [Overture Maps](https://overturemaps.org/)' public release instead, in place: nothing downloaded up front or hosted, about 10 s for each area plus a few seconds per extra pin nearby. Overture's buildings, roads and rail come from OSM, so results match the Geofabrik build:

```ruby
results = Curtilage.generate_many(pins, source: :overture)
```

Either way, the data host sees roughly which areas are read. For instant single lookups, build ahead of time instead:

```sh
curtilage build tennessee            # writes data/features/tennessee.parquet and tennessee.json
curtilage build europe/germany/bayern
```

Then, in Ruby:

```ruby
require "curtilage"

catalogue = Curtilage::Catalogue.from_dir("data/features")   # or base_url: "s3://bucket/features"
results = Curtilage.generate_many([[-80.0, 35.0], [-80.1, 35.2]], catalogue: catalogue)

result = results.first
result.ok?          # a ring that passed validation; never save one that isn't
result.ring         # [[lng, lat], ...], closed
result.flags        # reasons a person should look: near_houses, large_building, fallback, ...
result.explanation  # how it was made, step by step
result.to_geojson   # a GeoJSON Feature with all of the above and the attribution
```

- One pin: `Curtilage.generate(pin, Curtilage::Lookup.features(parquet: path, pin: pin))`.
- Styles: `preset: :whole_lot` (the default: the building and its whole lot), `preset: :tight` (the building plus a small margin) or `preset: :centre` (like whole_lot, but a store on a shared shopping-centre lot gets the whole centre, flagged `shopping_centre`). Any option overrides a preset.
- Check an existing polygon: `Curtilage::Audit.check(pin, ring, features)` returns `:ok`, `:review` (with reasons such as `crosses_road` or `covers_neighbour`) or `:invalid`.
- Parquet files can be local or in a bucket (`s3://`, `gs://`, `https://`, read in place). Credentials for a private bucket go in `lookup: { setup_sql: "CREATE SECRET ..." }`.

From the shell: `curtilage generate --catalogue data/features --pin -80.0,35.0` prints the GeoJSON. Set `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` if the DuckDB CLI or its extensions aren't in the default places.

### Speed

Per site: about 85 ms to look features up (one DuckDB call can serve many pins) and about 100 ms to generate (median; a few hundred milliseconds in dense blocks). Building a state takes 1-5 minutes and happens ahead of time.

## Development

```sh
bundle install
bundle exec rake test
```

Building and lookup need the [DuckDB](https://duckdb.org/) CLI (1.4 LTS) with the `spatial` extension, and `unzip`. Point `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` at them if they aren't in the default places.

## Data and licensing

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available under the [ODbL](https://opendatacommons.org/licenses/odbl/). Show this attribution wherever generated premises are displayed.
- If you opt in to ML footprints: Microsoft Global ML Building Footprints, also ODbL. Attribute them too.
- With `source: :overture`, data comes from the Overture Maps Foundation's release (buildings and transportation under ODbL); results carry the attribution to show.
- Downloaded files and the Parquet output are OSM-derived data. They're never committed to this repository (see `.gitignore`).
- This repository must never contain real site locations, client data or credentials. Tests and examples use made-up coordinates.
- The licence for this code is to be decided before publishing.
