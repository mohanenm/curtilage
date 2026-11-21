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

```ruby
require "curtilage"

pin = [-80.0, 35.0] # [lng, lat]
features = Curtilage::Lookup.features(parquet: "data/features/<region>.parquet", pin: pin)
result = Curtilage.generate(pin, features)
result.ok?         # usable: a ring that passed validation
result.ring        # [[lng, lat], ...], closed
result.flags       # reasons a person should look first
result.explanation # how it was made, step by step
```

Or from the shell: `curtilage generate --parquet data/features/<region>.parquet --pin -80.0,35.0`. Set `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` if the DuckDB CLI or its extensions aren't in the default places.

## Development

```sh
bundle install
bundle exec rake test
```

Building and lookup need the [DuckDB](https://duckdb.org/) CLI (1.4 LTS) with the `spatial` extension, and `unzip`. Point `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` at them if they aren't in the default places.

## Data and licensing

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available under the [ODbL](https://opendatacommons.org/licenses/odbl/). Show this attribution wherever generated premises are displayed.
- If you opt in to ML footprints: Microsoft Global ML Building Footprints, also ODbL. Attribute them too.
- Downloaded files and the Parquet output are OSM-derived data. They're never committed to this repository (see `.gitignore`).
- This repository must never contain real site locations, client data or credentials. Tests and examples use made-up coordinates.
- The licence for this code is to be decided before publishing.
