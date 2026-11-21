# Changelog

## [Unreleased]

- Geometry and validation for premises polygons.
- DuckDB query that builds a region's features Parquet from Geofabrik shapefiles.
- Premises generation: grow from the building and trim at public roads and neighbours, with a building-rectangle fallback, review flags and an explanation.
- Premises stop near the kerb (half a typical road width short of the centreline, by road class, never into the building), cuts follow each road's overall direction beside the site (nearest road first, snapped square to the building within 5 degrees), and cuts at neighbours are square to the building, 3 m short of the neighbour's wall (halfway when the gap is narrower). Grow distance 30 m.
- Mapped parking within 20 m of the building is claimed as its lot (up to the kerb, at most 60 m out), split halfway where a lot also touches a neighbour, and kept 1 m clear of neighbouring buildings.
- Railways at ground level bound premises like public roads (5 m short of the track). The build keeps surface rail, light rail, subway and narrow gauge, and drops roads and railways in tunnels or on bridges.
- Store zone: `result.store_ring` is the building's OSM outline (any shape, simplified to at most 20 corners without crossing itself), for an in-store zone; `to_geojson(include_store: true)` returns both. Buildings over 1,500 m2 are flagged `store_may_be_unit`.
- `scope: :centre` (preset `:centre`): a store on a shared shopping-centre lot gets the whole centre (the shared lots and every building on them, bounded by roads), flagged `shopping_centre`.
- Feature lookup from a features Parquet file through the DuckDB CLI, and a `curtilage generate` command.
- `curtilage build REGION`: downloads the newest dated Geofabrik extract for any US state or Geofabrik region, checks the zip, reads every part of split layers, and builds the Parquet file with memory capped for a 1 GB dyno.
- Optional machine-learned building footprints (Microsoft, ODbL): `--ml-footprints microsoft` at build time, `buildings: :osm_filled` or `:ml` at generate time, flagged `ml_footprint`. OSM only remains the default.
- A parking lot touching three or more other buildings is treated as shared (a shopping-centre lot) and claimed only within 30 m of the building; a lot shared with one or two buildings is claimed whole (split halfway only with homes). Driveways linking the lot to a public road are taken in up to the kerb. Buildings under 50 m2 are flagged `small_building`; when the pin isn't on a building, a real building in reach beats a tiny canopy, which then counts as lot.
- The build keeps OSM's building type. Parking garages, carports and canopies next to the building are claimed as part of the lot; homes (typed, or untyped small buildings in a row) are flagged `near_houses`: split halfway when the site is behind the home (its back yard, judged by which way it faces its street), otherwise the usual 3 m strip.
- Flags were checked against site ratings and trimmed to the ones that point at problems: `large_building` now means over 5,000 m2, and attached buildings and shared lots are explained but no longer flagged.
- The build downloads only the layers it uses, with HTTP range requests (about 30-60% fewer bytes), checks every file's CRC, and no longer needs `unzip` unless a server can't do ranges.
- Features repeated along the seam of a multi-part region are read once.
- Builds write `<region>.json` beside the Parquet file (source dates, extent, counts, licence, attribution); `Catalogue.from_dir` uses them to pick the file(s) covering each pin, locally or in a bucket.
- `Curtilage.generate_many`, batch lookups (`Lookup.features_many`), reading Parquet from `s3://`, `gs://` and `https://`, `Result#to_geojson`, presets (`:whole_lot`, `:tight`) and `Audit.check` for existing polygons.
- Data on demand: `generate_many(pins)` with no data finds each pin's region in Geofabrik's index (worldwide), builds only those regions into a temporary folder (or `cache_dir:`, reused for a month, with a lock so concurrent jobs build once) and cleans up. Nothing to host.
- `source: :overture`: read features in place from Overture Maps' latest release, using its file index to touch only the files covering each pin. No download, no hosting; about 10 s per area. Matches the Geofabrik build on test points (overlap 0.93-1.0).
- Generation is several times faster in dense areas: cheap bounding-box checks before exact geometry tests.
- Validation errors on polygons over 100,000 m2 (`too_large`).
