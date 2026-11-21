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
- A parking lot touching three or more other buildings is treated as shared (a shopping-centre lot): left out and flagged `shared_parking`. Buildings under 50 m2 are flagged `small_building`.
- Features repeated along the seam of a multi-part region are read once.
- Validation errors on polygons over 100,000 m2 (`too_large`).
