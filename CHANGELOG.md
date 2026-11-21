# Changelog

## [Unreleased]

- Geometry and validation for premises polygons.
- DuckDB query that builds a region's features Parquet from Geofabrik shapefiles.
- Premises generation: grow from the building and trim at public roads and neighbours, with a building-rectangle fallback, review flags and an explanation.
- Premises stop near the kerb (half a typical road width short of the centreline, by road class, never into the building), and cuts at neighbours and near-parallel roads (within 30 degrees) are square to the building. Grow distance 30 m.
- Mapped parking within 20 m of the building is claimed as its lot (up to the kerb, at most 60 m out), split halfway where a lot also touches a neighbour, and kept 1 m clear of neighbouring buildings.
- Feature lookup from a features Parquet file through the DuckDB CLI, and a `curtilage generate` command.
- Validation errors on polygons over 100,000 m2 (`too_large`).
