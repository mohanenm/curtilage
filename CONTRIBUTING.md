# Contributing to curtilage

Thanks for helping. Bug reports, bad-polygon reports, benchmark sites and code are all welcome. By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md).

## The one rule: no real site data

**Never put private or customer site locations anywhere in this repository, its issues or its pull requests**: not in code, tests, examples, screenshots or benchmark files. Use made-up coordinates (the tests use points near `[-80.0, 35.0]`) or a well-known public place that anyone can look up. A list of where a business's sites are can be confidential even without names.

## Setting up

You need Ruby 3.2 or newer and the [DuckDB CLI](https://duckdb.org/docs/installation/) (1.4 LTS or 2.0).

```sh
git clone https://github.com/mohanenm/curtilage.git && cd curtilage
bundle install
bundle exec exe/curtilage doctor     # checks DuckDB and its extensions
```

## Tests and lint

```sh
bundle exec rake          # tests (Minitest), then RuboCop
bundle exec rake test     # tests only
```

Integration tests (`test/integration_test.rb`) run against a real DuckDB on a made-up region when one is installed, and are skipped otherwise. CI runs everything on Ruby 3.2, 3.3 and 3.4.

## Map data

- `bundle exec exe/curtilage build <state or geofabrik/path> --out data/features [--ml-footprints microsoft]` builds a region's features file: it finds the newest dated Geofabrik extract, range-downloads only the layers it uses, and writes `data/features/<region>.parquet` and `.json` with memory capped at 400 MB. Set `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` if DuckDB isn't in the default places (on macOS the extension folder must be an absolute path).
- `data/` is gitignored: downloads, built Parquet, caches and anything private. Never commit OSM files or Parquet output (ODbL data, and large).
- Geofabrik: use dated files (`<region>-YYMMDD-free.shp.zip`), not `latest`, which can 404 during their daily publish; the build checks each file's CRC. Dated `.osm.pbf` files live one folder deeper (`north-america/us/<state>/`). Large layers can be split into `_1`, `_2`, …, and California comes only as `norcal` and `socal`: the build reads every part.
- No region-specific tuning in the rules: the gem should work wherever the map data reaches.

## Changes to the rules

Anything that changes the polygons curtilage produces needs the public benchmark run before and after:

```sh
bundle exec rake benchmark                               # writes data/benchmark/runs/<time>-<commit>.json
bundle exec rake "benchmark:compare[OLD.json,NEW.json]"  # what changed, per site and per view
```

See [benchmark/README.md](benchmark/README.md). Say in the pull request what changed on the benchmark, per view.

**How changes are judged.** On aerial imagery and the benchmark's labelled points, not only on overlap (IoU) with a hand-drawn polygon: hand-drawn premises are often tighter than the whole customer-facing lot curtilage aims for. A change that takes in more of what should be in without taking in roads, neighbours' buildings or homes is an improvement even if IoU drops. Held-out benchmark sites are never used to tune anything; they're for a final check.

## Reporting a bad polygon

Use the **Bad polygon** issue template. Please include:

- a **public place** (its name and address) or **made-up coordinates**, never a private site;
- what you expected and what you got;
- the result's flags, confidence and the options you used (or the profile and preset);
- the data source and release (`provenance` in the GeoJSON output has both);
- a screenshot of `curtilage preview --pin LNG,LAT` (it draws only map data, no imagery).

## Reporting a security problem

Privately, through GitHub's **Security** tab → **Report a vulnerability**. Don't open a public issue. See [SECURITY.md](SECURITY.md).

## Pull requests

- Keep each pull request to one change, with tests.
- AI-assisted contributions are welcome when you have read and tested what you submit. [AGENTS.md](AGENTS.md) has the instructions for coding agents.
- Update [docs/reference.md](docs/reference.md) for any option, flag, output or command you add or change, and the [CHANGELOG](CHANGELOG.md) under Unreleased (**Breaking** for anything that changes the public API, with how to update).
- Run the benchmark if results change.
- Treat map data and input as untrusted: cap sizes and vertex counts, escape text in outputs, never build SQL from map values.
- Comments explain why, not what.
