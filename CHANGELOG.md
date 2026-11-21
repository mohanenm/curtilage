# Changelog

## [Unreleased]

- Geometry and validation for premises polygons.
- DuckDB query that builds a region's features Parquet from Geofabrik shapefiles.
- Premises generation: grow from the building and trim at public roads and neighbours, with a building-rectangle fallback, review flags and an explanation.
- Premises stop near the kerb (half a typical road width short of the centreline, by road class, never into the building), cuts follow each road's overall direction beside the site (nearest road first, snapped square to the building within 5 degrees), and cuts at neighbours are square to the building, 3 m short of the neighbour's wall (halfway when the gap is narrower). Grow distance 30 m.
- Mapped parking within 20 m of the building is claimed as its lot (up to the kerb, at most 60 m out), split halfway where a lot also touches a neighbour, and kept 1 m clear of neighbouring buildings.
- Railways at ground level bound premises like public roads (5 m short of the track). The build keeps surface rail, light rail, subway and narrow gauge, and drops roads and railways in tunnels or on bridges.
- Feature lookup from a features Parquet file through the DuckDB CLI, and a `curtilage generate` command.
- `curtilage build REGION`: downloads the newest dated Geofabrik extract for any US state or Geofabrik region, checks the zip, reads every part of split layers, and builds the Parquet file with memory capped for a 1 GB dyno.
- Optional machine-learned building footprints (Microsoft, ODbL): `--ml-footprints microsoft` at build time, `buildings: :osm_filled` or `:ml` at generate time, flagged `ml_footprint`. OSM only remains the default.
- A parking lot touching three or more other buildings is treated as shared (a shopping-centre lot) and left out. Buildings under 50 m2 are flagged `small_building`.
- The build keeps OSM's building type. Parking garages, carports and canopies next to the building are claimed as part of the lot; homes (typed, or untyped small buildings in a row) are split halfway rather than claimed up to their walls, and flagged `near_houses`.
- Flags were checked against site ratings and trimmed to the ones that point at problems: `large_building` now means over 5,000 m2, and attached buildings and shared lots are explained but no longer flagged.
- The build downloads only the layers it uses, with HTTP range requests (about 30-60% fewer bytes), checks every file's CRC, and no longer needs `unzip` unless a server can't do ranges.
- Features repeated along the seam of a multi-part region are read once.
- Builds write `<region>.json` beside the Parquet file (source dates, extent, counts, licence, attribution); `Catalogue.from_dir` uses them to pick the file(s) covering each pin, locally or in a bucket.
- `Curtilage.generate_many`, batch lookups (`Lookup.features_many`), reading Parquet from `s3://`, `gs://` and `https://`, `Result#to_geojson`, presets (`:whole_lot`, `:tight`) and `Audit.check` for existing polygons.
- Data on demand: `generate_many(pins)` with no data finds each pin's region in Geofabrik's index (worldwide), builds only those regions into a temporary folder (or `cache_dir:`, reused for a month, with a lock so concurrent jobs build once) and cleans up. Nothing to host.
- Generation is several times faster in dense areas: cheap bounding-box checks before exact geometry tests.
- Validation errors on polygons over 100,000 m2 (`too_large`).
