# Changelog

## [Unreleased]

- Geometry and validation for premises polygons.
- DuckDB query that builds a region's features Parquet from Geofabrik shapefiles.
- Premises generation: grow from the building and trim at public roads and neighbours, with a building-rectangle fallback, review flags and an explanation.
- Feature lookup from a features Parquet file through the DuckDB CLI, and a `curtilage generate` command.
- Validation errors on polygons over 100,000 m2 (`too_large`).
