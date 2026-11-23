# Outputs and ways in (review phase 8)

What was added for people who don't write Ruby, and what was assessed but not built.

## Built

- **Geofence shapes**: `enclosing_circle` and `fit_circle` on every result (and in GeoJSON, NDJSON and CSV), `Result#simplified(n)` / `--simplify N`.
- **GIS formats**: GeoParquet, GeoPackage and FlatGeobuf through DuckDB (its spatial extension includes GDAL), from the NDJSON a run streams. No new dependency. FlatGeobuf keeps only sites with premises: its spatial index can't hold an empty geometry, and DuckDB's own reader fails on one.
- **HTTP server**: `curtilage serve` on the standard library; spec in `docs/openapi.yaml`.
- **Helpers and recipes**: `Curtilage.point_in_premises?`, `docs/recipes/`, a Homebrew formula (`packaging/`).

## H3 cells (not built: needs a decision)

An H3 cover of each premises at a chosen resolution. Two ways:

1. **DuckDB's `h3` community extension** (`INSTALL h3 FROM community`): `h3_polygon_wkt_to_cells`, mature and fast. But community extensions are built and signed by DuckDB from a third party's code, a step down from the core extensions the gem trusts now, and a new thing to install and keep current.
2. **H3 in plain Ruby**: the hierarchical icosahedral projection, cell boundaries and polygon fill. Several hundred lines of careful numeric code to write and test against the reference implementation; not small.

Recommendation: the extension, opt-in (an `--h3 RES` flag that installs it only when asked), documented as a community extension. Or leave H3 to users: GeoParquet loads straight into DuckDB, where they can run the extension themselves.

## PMTiles for large batches (assessed only)

PMTiles packs vector tiles into one file a web map reads over HTTP range requests. Writing it needs tiling (simplification per zoom, clipping to tiles, MVT encoding) and the PMTiles directory format. Tippecanoe does all of that from GeoJSON or FlatGeobuf and is the usual tool (`tippecanoe -o premises.pmtiles premises.fgb`); DuckDB doesn't write PMTiles. Recommendation: document the Tippecanoe step rather than reimplement it; revisit if users ask for one-step output.

## QGIS plugin (assessed only)

A plugin could add a map tool (click a point, get the premises as a scratch layer) and a processing algorithm (a point layer in, a premises layer out). Its options would be the CLI's generation options, results loaded with the flags, confidence and explanation as attributes.

It would call `curtilage serve` on 127.0.0.1 (simplest: plain HTTP from Python, no Ruby in QGIS's environment) or the CLI with NDJSON in and out (no server to run, but QGIS must find Ruby and the gem). Either way the plugin stays a thin wrapper: the Ruby gem is the only engine.

Open points: packaging Ruby and DuckDB for QGIS users on Windows (the Docker image may be the practical answer); the plugin repository's licence (GPL is required for QGIS plugins, which is compatible with calling an MIT tool); and where a click sends coordinates (nowhere but the local server or CLI, which is the point).

## Waiting for a decision

- H3: extension or not (above).
- Publishing the Docker image to GitHub Container Registry, and the Homebrew tap: both written, neither turned on.
- The Python package: `python/` in this repository, or a separate repository.
