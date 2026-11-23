# Core features (Phase 6): design notes

Short notes on each Phase 6 feature: what it adds, the choices made and why. The reference documents the result.

## 6.1 Reproducibility and provenance

Each result carries `provenance`: gem version, data source and release, every option after defaults, and `features_sha256`, a hash of the map data it was made from.

- **Release.** For Overture it's the release name, settled once per call so every result in a batch names the same one. For Geofabrik builds and catalogues it's each region's extract dates, from the build's metadata. Microsoft footprints publish no dates, so the build's date stands in.
- **The hash** covers every input feature in a canonical form (keys sorted and stringified, lines sorted), so it doesn't depend on the order DuckDB returns rows or on how a caller writes keys. Same hash, version and options means same inputs.
- **No timestamps** in results or outputs. A `generated_at` would make every run differ; callers who want one add it themselves.
- **`precision:`** (default 7, about 1 cm) rounds coordinates before validation, so the polygon that was checked is the one written.
- **Order.** The rules used to depend on the order features arrived in (neighbour cuts were applied in input order), and DuckDB doesn't promise row order. See the decision below.

## 8.2 A stable CLI contract

(Pulled ahead of Phase 8 because the provenance and NDJSON schema go together.)

- `--format ndjson`: one GeoJSON Feature per line (GeoJSONSeq without the record separator), so GDAL, QGIS, tippecanoe and DuckDB read it directly and any language can parse it line by line. The store zone is a geometry in `properties.store`. Schema: `docs/schema/site-v1.json`.
- NDJSON in: each line `{"id","lng","lat"}`, `{"id","pin":[lng,lat]}` or a GeoJSON Point Feature; `--in -` reads standard input.
- Exit codes: 0 ok, 1 some sites failed, 2 bad input or usage, 3 missing dependency (DuckDB or extensions), 4 data unavailable (downloads, Overture, offline mode). Errors carry their class (`Curtilage::DependencyError`, `Curtilage::DataUnavailable`) so the CLI never matches on message text.
- Logs go to standard error only; `--quiet` keeps errors only and `--log-format json` writes one JSON object per line.

### Decision: making results independent of input order

Shuffling the input changes the polygon on about a fifth of real sites, nearly all through the order of neighbour cuts. The options:

- **A. Sort the input** into a fixed order before the rules run. Deterministic, but the order has no meaning.
- **B. Cut at the nearest neighbour first** (ties by id). A rule that doesn't care about input order; A then covers what's left (one road case).

Recommended: B with A. Waiting on approval, as it changes results.
