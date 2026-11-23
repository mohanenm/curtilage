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
- Exit codes: 0 ok, 1 some sites failed, 2 bad input or usage, 3 missing dependency (DuckDB or extensions), 4 data unavailable (downloads, Overture, offline mode), 70 an unexpected error. The CLI maps by class, never by message: `ArgumentError` is 2, `Curtilage::DependencyError` 3, any other `Curtilage::Error` 4. A crash gets 70 rather than Ruby's default 1, so 1 always means "output written, some sites failed". A separate `DataUnavailable` class was left out: every other gem error already is one.
- Logs go to standard error only; `--quiet` keeps errors only and `--log-format json` writes one JSON object per line.

### Decision: making results independent of input order

Shuffling the input changed the polygon on 32 of 164 real sites, nearly all through the order of neighbour cuts (each cut works on what the ones before it left). Chosen (2026-11-23):

- **Nearest neighbour first** (ties by id): the closest building bounds the lot most, so it's cut first. Only the buildings a cut considers are sorted, which keeps generation as fast as before.
- **The input is sorted** into one canonical order before the rules run, covering the rest (one road case) and making the 20,000-feature cap take the same features every time.

On the private held-out set this gives the same answer for every input order. Mean IoU went from 0.469 to 0.466; today's 0.469 came from one lucky order, and random orders gave 0.464-0.466. Slanted road edges went from 7 sites to 8.
