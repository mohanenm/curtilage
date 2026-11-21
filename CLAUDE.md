# curtilage

Ruby gem that generates a site's premises polygon (the building and its customer-facing lot) and a store zone (the building's outline) from free map data. See [README.md](README.md) for what it does, the options and the measured numbers.

## Commands

- Tests and lint: `bundle exec rake` (Minitest, then RuboCop). Tests only: `bundle exec rake test`.
- Build a region's features file: `CURTILAGE_DUCKDB=$PWD/data/bin/duckdb CURTILAGE_EXTENSIONS=$PWD/data/bin/extensions bundle exec exe/curtilage build <state or geofabrik/path> [--ml-footprints microsoft]`. It finds the newest dated Geofabrik extract, range-downloads only the layers it uses, and writes `data/features/<region>.parquet` and `.json` with memory capped at 400 MB. On macOS the extension directory must be an absolute path.
- Private evaluation scripts and the review pages live in gitignored `data/eval/`; `data/HANDOFF.md` (also gitignored) has the project state and how to run them.

## Conventions

- Coordinates are `[lng, lat]` everywhere, as in GeoJSON. Rings are closed (first point = last).
- Geometry is plain Ruby (`Curtilage::Geometry`): a flat projection around the pin, accurate to well under a metre at premises scale. Don't add a geometry gem without a reason. The gem has no runtime gem dependencies; DuckDB is used through its CLI.
- Every generated polygon goes through `Curtilage::Validation.check` before it's offered. The store zone must always sit inside the premises.
- Rule-based only: no machine learning in the method. ML footprints are an opt-in data flavour (`buildings:`).
- Treat map data as untrusted: cap file sizes and vertex counts, and drop empty or invalid geometry.
- Judge changes to the rules on aerial imagery and reviewer ratings, not only on IoU against hand-drawn polygons (they're often tighter than the goal).
- Comments explain why, not what.

## Data

- `data/` is gitignored: downloads, built Parquet, the DuckDB binary, and private evaluation data. Never commit OSM files or Parquet output (they're ODbL data, and large).
- Geofabrik: use dated files (`<state>-YYMMDD-free.shp.zip`), not `latest`, which can 404 during their daily publish. Shapefiles have no published checksum; the build checks each file's CRC. Dated `.osm.pbf` files live one folder deeper (`north-america/us/<state>/`).
- Large layers can be split into `_1`, `_2`, …, and California only comes as `norcal` and `socal`: the build reads every part.
- The goal is every US state, and the gem should stay usable outside the US and outside any one company: no state-specific tuning.

## Rules

- **This repository may become public. Never add real site locations, client names or data, or credentials.** Tests and examples use made-up coordinates. Private evaluation data stays in `data/eval/`.
- Network access only to public map-data hosts (Geofabrik, Overture Maps, Microsoft's footprint files when opted in) and DuckDB's extension repository. Never send real site locations anywhere else.
- Git: stage files by explicit path (never `git add -A`, `git add .` or `commit -a`), check `git diff --cached --stat` before committing, no Co-Authored-By trailer, and don't push unless asked. Other sessions may be working in the same folder, so run `git status` first.
