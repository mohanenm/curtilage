# curtilage

Ruby gem that generates a site's premises polygon (building + pickup/parking area) from OpenStreetMap data. See [README.md](README.md) for what it does and the measured numbers.

## Commands

- Tests: `bundle exec rake test`
- Build a region's features file (DuckDB CLI 1.4 LTS with the `spatial` extension):
  ```
  SET extension_directory='data/bin/extensions'; LOAD spatial;
  SET VARIABLE shp_dir = '<unzipped Geofabrik shapefiles>';
  SET VARIABLE out_path = 'data/features/<region>.parquet';
  .read sql/build_from_shapefiles.sql
  ```
  Feed this to the CLI on stdin (`data/bin/duckdb < file.sql`). Dot commands don't work with `-c`.
  On macOS, `extension_directory` must be an absolute path: the signed binary refuses to load extensions from a relative one.

## Conventions

- Coordinates are `[lng, lat]` everywhere, as in GeoJSON. Rings are closed (first point = last).
- Geometry is plain Ruby (`Curtilage::Geometry`): a flat projection around the pin, accurate to well under a metre at premises scale. Don't add a geometry gem without a reason.
- Every generated polygon goes through `Curtilage::Validation.check` before it's offered.
- Treat OSM data as untrusted: cap file sizes and vertex counts, and drop empty or invalid geometry.
- Comments explain why, not what.

## Data

- `data/` is gitignored: downloads, built Parquet, the DuckDB binary, and private evaluation data. Never commit OSM files or Parquet output (they're ODbL data, and large).
- Geofabrik: download dated files (`<state>-YYMMDD-free.shp.zip`), not `latest`, which can 404 during their daily publish. Shapefiles have no published MD5, so check zip CRCs with `unzip -t`.
- Large layers can be split into `_1`, `_2`, …: read `gis_osm_*_free_*.shp`.

## Rules

- **This repository may become public. Never add real site locations, client names or data, or credentials.** Tests and examples use made-up coordinates. Private evaluation data stays in `data/eval/`.
- No outside network calls at runtime. The only network access is downloading public map files.
- Git: stage files by explicit path (never `git add -A`, `git add .` or `commit -a`), check `git diff --cached --stat` before committing, no Co-Authored-By trailer, and don't push unless asked. Other sessions may be working in the same folder, so run `git status` first.
