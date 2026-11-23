# Core features (Phase 6): design notes

Short notes on each Phase 6 feature: what it adds, the choices made and why. The reference documents the result.

## 6.1 Reproducibility and provenance

Each result carries `provenance`: gem version, data source and release, every option after defaults, and `features_sha256`, a hash of the map data it was made from.

- **Release.** For Overture it's the release name, settled once per call so every result in a batch names the same one. For Geofabrik builds and catalogues it's each region's extract dates, from the build's metadata. Microsoft footprints publish no dates, so the build's date stands in.
- **The hash** covers every input feature in a canonical form (keys sorted and stringified, lines sorted), so it doesn't depend on the order DuckDB returns rows or on how a caller writes keys. Same hash, version and options means same inputs.
- **No timestamps** in results or outputs. A `generated_at` would make every run differ; callers who want one add it themselves.
- **`precision:`** (default 7, about 1 cm) rounds coordinates before validation, so the polygon that was checked is the one written.
- **Order.** The rules used to depend on the order features arrived in (neighbour cuts were applied in input order), and DuckDB doesn't promise row order. See the decision below.

## 6.2 Confidence score

`Result#confidence`, 0 to 1, with `confidence_factors` listing every factor. Each unmet factor takes its weight off 1 (floor 0). A penalty sum rather than a normalised average, so one serious problem (a fallback, 0.30) counts fully whatever else is fine, and an invalid result (weight 1.0) is always 0.

- **Factors** come only from what the result already knows (flags, details, validation), so the score explains itself and adds no new rules.
- **No data age.** "Data fresh" was suggested, but scoring by today's date makes the same inputs score differently over time, which breaks 6.1. The release is in `provenance` for anyone who wants to age-filter.
- **Weights are judgement**, set before measuring. They may only be calibrated on the public benchmark (no tuning on private data), and its reference polygons aren't drawn yet.
- **First measurement** (private held-out set, aggregate only, weights not tuned to it): the 17 lowest-confidence sites (bottom 10%) hold all 5 invalid results and have mean IoU 0.25 against 0.49 for the rest; 10 of the 31 sites under IoU 0.3 land there. Among valid results the ranking is weak (Spearman 0.14 against IoU), and IoU against hand-drawn polygons, which are tighter than the goal, is itself a weak measure. So: good at surfacing the clearly bad, not yet at ordering the rest. Calibrate on the benchmark and on review outcomes (accept / nudge / redraw).
- **`--min-confidence N`** leaves results below N out of the output (exit 1, count on stderr), giving a file of results to save unattended while the rest go to review. The preview sorts by confidence instead of filtering, as it's for review.

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
