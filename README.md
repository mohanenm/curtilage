# curtilage

*Curtilage: the land immediately around a building, such as its yard, drive and lot.*

Generates a site's **premises polygon** (the building plus its pickup and parking area) from OpenStreetMap data, so nobody has to draw it by hand.

**Status:** early. The validation and geometry are in place; the build, lookup and generation are being developed.

## How it works

1. **Build** (once a month per region). Download a region's OpenStreetMap shapefiles from [Geofabrik](https://download.geofabrik.de/), keep buildings, parking and drivable roads, and write one Parquet file sorted by location. Tennessee: a 363 MB download becomes a 256 MB file, built in about 15 seconds with under 1 GB of memory.
2. **Look up.** Read the buildings, parking and roads around a point from that file. That takes about 5 ms, because only the row groups near the point are read.
3. **Generate.** Propose a polygon from the building under the pin, extended toward its lot and trimmed at public roads, with an explanation of each step.
4. **Validate.** Reject or flag polygons that are unsafe to use: pin outside, unclosed, self-intersecting, swapped coordinates, too far from the pin, an implausible size.

Nothing calls an outside service at runtime. The only network access is the monthly download of public map files.

Coordinates are `[lng, lat]` throughout, as in GeoJSON.

## Layout

| Path | What |
|---|---|
| `lib/curtilage/geometry.rb` | Plain-Ruby planar geometry (area, containment, hull, minimum rotated rectangle) |
| `lib/curtilage/validation.rb` | Checks a polygon against its pin, returning errors, warnings and metrics |
| `sql/build_from_shapefiles.sql` | DuckDB query: Geofabrik shapefiles to a features Parquet file |
| `test/` | Tests, using synthetic coordinates only |

## Development

```sh
bundle install
bundle exec rake test
```

The build needs the [DuckDB](https://duckdb.org/) CLI (1.4 LTS) with the `spatial` extension.

## Data and licensing

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available under the [ODbL](https://opendatacommons.org/licenses/odbl/). Show this attribution wherever generated premises are displayed.
- Downloaded files and the Parquet output are OSM-derived data. They're never committed to this repository (see `.gitignore`).
- This repository must never contain real site locations, client data or credentials. Tests and examples use made-up coordinates.
- The licence for this code is to be decided before publishing.
