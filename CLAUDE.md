# curtilage

Ruby gem that generates a site's premises polygon (the building and its customer-facing lot) and a store zone (the building's outline) from free map data. See [README.md](README.md) for what it does and [docs/reference.md](docs/reference.md) for every option. Keep both in step with the code: the gem must stay simple to use and fully documented.

If `data/AGENT_NOTES.md` exists, read it too.

## Commands

- Tests and lint: `bundle exec rake` (Minitest, then RuboCop). Tests only: `bundle exec rake test`.
- Build a region's features file: `bundle exec exe/curtilage build <state or geofabrik/path> --out data/features [--ml-footprints microsoft]`. It finds the newest dated Geofabrik extract, range-downloads only the layers it uses, and writes `data/features/<region>.parquet` and `.json` with memory capped at 400 MB. Point `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` at a DuckDB CLI and extension folder if they aren't in the default places; on macOS the extension folder must be an absolute path.
- `bundle exec exe/curtilage doctor` checks that DuckDB and its extensions are ready.

## Conventions

- Coordinates are `[lng, lat]` everywhere, as in GeoJSON. Rings are closed (first point = last).
- Geometry is plain Ruby (`Curtilage::Geometry`): a flat projection around the pin, accurate to well under a metre at premises scale. Don't add a geometry gem without a reason. The gem has no runtime gem dependencies; DuckDB is used through its CLI.
- Every generated polygon goes through `Curtilage::Validation.check` before it's offered. The store zone must always sit inside the premises.
- Rule-based only: no machine learning in the method. ML footprints are an opt-in data flavour (`buildings:`).
- Treat map data and user input as untrusted: cap file sizes and vertex counts, and drop empty or invalid geometry.
- Judge changes to the rules on aerial imagery, not only on IoU against hand-drawn polygons (those are often tighter than the goal).
- Comments explain why, not what.

## Data

- `data/` is gitignored: downloads, built Parquet files, local tools and anything private. Never commit OSM files or Parquet output (they're ODbL data, and large).
- Geofabrik: use dated files (`<region>-YYMMDD-free.shp.zip`), not `latest`, which can 404 during their daily publish. Shapefiles have no published checksum; the build checks each file's CRC. Dated `.osm.pbf` files live one folder deeper (`north-america/us/<state>/`).
- Large layers can be split into `_1`, `_2`, …, and California only comes as `norcal` and `socal`: the build reads every part.
- The gem should work wherever the map data reaches, for any user: no region-specific tuning in the rules.

## Rules

- **Never commit real site locations, private data or credentials.** Tests and examples use made-up coordinates, or well-known public places.
- Network access only to public map-data hosts (Geofabrik, Overture Maps, Microsoft's footprint files when opted in) and DuckDB's extension repository. Never send site locations anywhere else.
- Git: stage files by explicit path (never `git add -A`, `git add .` or `commit -a`), check `git diff --cached --stat` before committing, no Co-Authored-By trailer, and don't push unless asked. Other sessions may be working in the same folder, so run `git status` first.
