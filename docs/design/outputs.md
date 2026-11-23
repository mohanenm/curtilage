# Outputs and ways in (review phase 8)

What was added for people who don't write Ruby, and what was assessed but not built.

## Built

- **Geofence shapes**: `enclosing_circle` and `fit_circle` on every result (and in GeoJSON, NDJSON and CSV), `Result#simplified(n)` / `--simplify N`.
- **GIS formats**: GeoParquet, GeoPackage and FlatGeobuf through DuckDB (its spatial extension includes GDAL), from the NDJSON a run streams. No new dependency. FlatGeobuf keeps only sites with premises: its spatial index can't hold an empty geometry, and DuckDB's own reader fails on one.
- **HTTP server**: `curtilage serve` on the standard library; spec in `docs/openapi.yaml`.
- **Helpers and recipes**: `Curtilage.point_in_premises?`, `docs/recipes/`, a Homebrew formula (`packaging/`).

## H3 cells

`--h3 RES` (or `Curtilage::H3.cover(results, res)`) lists the H3 cells each premises touches ("overlap" cover, so even a small site gets one), in every output. It runs through DuckDB's community `h3` extension, installed only when asked for. Community extensions are built and signed by DuckDB from third-party code, a step down from the core extensions used everywhere else, which is why it's opt-in. A plain-Ruby H3 (the icosahedral projection, cell boundaries, polygon fill) would be several hundred lines of numeric code to write and test against the reference implementation.

The extension follows DuckDB's releases with a lag: at the time of writing it's published for 1.4 LTS but not 2.0.1, where `--h3` stops with an error that says so.

## PMTiles for large batches (assessed only)

PMTiles packs vector tiles into one file a web map reads over HTTP range requests. Writing it needs tiling (simplification per zoom, clipping to tiles, MVT encoding) and the PMTiles directory format. Tippecanoe does all of that from GeoJSON or FlatGeobuf and is the usual tool (`tippecanoe -o premises.pmtiles premises.fgb`); DuckDB doesn't write PMTiles. Recommendation: document the Tippecanoe step rather than reimplement it; revisit if users ask for one-step output.

## QGIS plugin (assessed only)

A plugin could add a map tool (click a point, get the premises as a scratch layer) and a processing algorithm (a point layer in, a premises layer out). Its options would be the CLI's generation options, results loaded with the flags, confidence and explanation as attributes.

It would call `curtilage serve` on 127.0.0.1 (simplest: plain HTTP from Python, no Ruby in QGIS's environment) or the CLI with NDJSON in and out (no server to run, but QGIS must find Ruby and the gem). Either way the plugin stays a thin wrapper: the Ruby gem is the only engine.

Open points: packaging Ruby and DuckDB for QGIS users on Windows (the Docker image may be the practical answer); the plugin repository's licence (GPL is required for QGIS plugins, which is compatible with calling an MIT tool); and where a click sends coordinates (nowhere but the local server or CLI, which is the point).

## Not done here

- Publishing the Docker image to GitHub Container Registry and the Homebrew tap: both are written, neither is turned on.
- A Python wrapper.
